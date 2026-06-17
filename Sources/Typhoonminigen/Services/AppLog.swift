import Foundation

/// Minimal app logger: writes to a file (clearable) + keeps an in-memory ring buffer for the
/// in-app log viewer. Deliberately does NOT mirror to the macOS unified log: log lines carry
/// user content (seeds, image file names, LoRA names) and the system log outlives the in-app
/// "Clear logs" button — everything must stay in files the user can actually erase.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let lock = NSLock()
    private var buffer: [String] = []
    private let maxLines = 500
    // Single persistent FileHandle — avoids open/close overhead on every line (N-2).
    // Access is serialized by `lock`, so no data races on concurrent writes (C-3).
    private var fileHandle: FileHandle?

    static func info(_ m: String) { shared.write("INFO", m) }
    static func warn(_ m: String) { shared.write("WARN", m) }
    static func error(_ m: String) { shared.write("ERROR", m) }

    private func write(_ level: String, _ message: String) {
        lock.lock()
        // DateFormatter is not thread-safe → format inside the lock.
        let line = "\(Self.timeFormatter.string(from: Date())) [\(level)] \(message)"
        buffer.append(line)
        if buffer.count > maxLines { buffer.removeFirst(buffer.count - maxLines) }
        appendToFile(line)  // C-3: called under lock to prevent TOCTOU race on FileHandle position
        lock.unlock()
    }

    func recent() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    /// Clear the in-memory buffer and truncate the on-disk log (including the rotated `.1`
    /// generation). Returns bytes freed AND bytes still on disk afterwards — these logs carry
    /// user content (seeds, file names, LoRA names), so the UI must not falsely claim "0 left"
    /// if a truncate/remove actually failed.
    func clear() -> (freed: Int64, remaining: Int64) {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
        let url = AppPaths.logFile
        let rotated = url.appendingPathExtension("1")
        func totalSize() -> Int64 {
            var size: Int64 = 0
            for f in [url, rotated] {
                let attrs = try? FileManager.default.attributesOfItem(atPath: f.path)
                size += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            }
            return size
        }
        let before = totalSize()
        try? fileHandle?.close()
        fileHandle = nil
        try? Data().write(to: url)
        try? FileManager.default.removeItem(at: rotated)
        let remaining = totalSize()
        return (freed: max(0, before - remaining), remaining: remaining)
    }

    // Called under `lock`. Opens the handle once and reuses it; recreates after clear()/rotation.
    private func appendToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let url = AppPaths.logFile
        if fileHandle == nil {
            // The Logs directory may not exist yet (logging can fire before bootstrap()).
            let dir = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data().write(to: url)
            }
            fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? fileHandle?.seekToEnd()
        }
        try? fileHandle?.write(contentsOf: data)
        // Rotation: past ~1 MB keep a single .1 generation and start fresh, so the file can
        // never grow without bound (it claimed to be "rotating" long before it was).
        if let offset = try? fileHandle?.offset(), offset > 1_000_000 {
            try? fileHandle?.close()
            fileHandle = nil
            let rotated = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"  // multi-day logs need the date
        return f
    }()
}
