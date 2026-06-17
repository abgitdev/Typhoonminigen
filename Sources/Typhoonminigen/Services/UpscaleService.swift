import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

/// Wraps the official `realesrgan-ncnn-vulkan` binary (BSD-3, native arm64, runs on the M4
/// GPU): downloads it once (~50 MB) into Application Support/Tools, then upscales images
/// ×2/×4 in seconds. Verified LIVE on this Mac before wiring: 512²→2048² and -s 2 both OK.
enum UpscaleService {
    static let releaseURL = URL(string:
        "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip")!
    /// Supply-chain pin: SHA-256 of the official v0.2.5.0 macOS zip, computed from a fresh
    /// download and byte-compared against the shipped binary on 2026-06-10. A re-uploaded
    /// asset or corrupted download is rejected before anything gets executed.
    static let releaseZipSHA256 = "e0ad05580abfeb25f8d8fb55aaf7bedf552c375b5b4d9bd3c8d59764d2cc333a"

    static var toolDir: URL { AppPaths.appSupport.appendingPathComponent("Tools/realesrgan", isDirectory: true) }
    static var binary: URL { toolDir.appendingPathComponent("realesrgan-ncnn-vulkan") }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    // The tool process currently running (at most one — upscales are serialized by the
    // isUpscaling flags). Tracked so app quit can terminate it instead of orphaning a
    // GPU-heavy child to launchd.
    nonisolated(unsafe) private static var currentProcess: Process?
    /// One upscale end-to-end (download → exec). The canvas and gallery-detail entry points
    /// share this single child slot — without the gate two concurrent runs would clobber
    /// currentProcess (orphaning a GPU child on quit) and collide on the same output file.
    nonisolated(unsafe) private static var inFlight = false
    private static let processLock = NSLock()

    /// True while a realesrgan child is running — drives the quit-confirmation guard
    /// (covers the canvas AND gallery-detail entry points; the child is app-global).
    static var isRunning: Bool {
        processLock.lock(); defer { processLock.unlock() }
        return currentProcess?.isRunning == true
    }

    /// True for the WHOLE upscale operation — including the one-time ~50 MB upscaler download +
    /// install, not only while the child process runs. The quit/maintenance guards use this so a
    /// "Remove all data" or quit during the download phase is still caught.
    static var isBusy: Bool {
        processLock.lock(); defer { processLock.unlock() }
        return inFlight
    }

    /// Called from applicationWillTerminate: stop a running tool so it doesn't outlive the app.
    static func terminateCurrent() {
        processLock.lock(); defer { processLock.unlock() }
        currentProcess?.terminate()
    }

    /// Sync gate helpers (NSLock is unavailable from async contexts). acquireGate returns
    /// false if an upscale is already in flight.
    private static func acquireGate() -> Bool {
        processLock.lock(); defer { processLock.unlock() }
        if inFlight { return false }
        inFlight = true
        return true
    }
    private static func releaseGate() {
        processLock.lock(); defer { processLock.unlock() }
        inFlight = false
    }

    /// Upscale `input` by 2 or 4; returns the written `<name>_x<scale>.png` next to the input.
    static func upscale(
        _ input: URL,
        scale: Int,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        // Single global gate: refuse a second concurrent upscale (canvas vs gallery-detail).
        // The lock lives in a sync helper — NSLock can't be taken from an async context.
        guard acquireGate() else { throw UpscaleError.busy }
        defer { releaseGate() }

        if !isInstalled {
            onStatus("Downloading upscaler (~50 MB, one time)…")
            let (tmpZip, _) = try await URLSession.shared.download(from: releaseURL)
            defer { try? FileManager.default.removeItem(at: tmpZip) }
            onStatus("Verifying download…")
            try verify(zip: tmpZip)
            onStatus("Installing upscaler…")
            try await Task.detached(priority: .userInitiated) { try install(from: tmpZip) }.value
        }
        let stem = input.deletingPathExtension().lastPathComponent
        let dir = input.deletingLastPathComponent()
        let outURL = dir.appendingPathComponent("\(stem)_x\(scale).png")
        onStatus("Upscaling ×\(scale)…")
        try await Task.detached(priority: .userInitiated) {
            // realesrgan-x4plus is a NATIVE ×4 model — passing "-s 2" produces broken tiles
            // with transparent holes (user-hit). Always run the real ×4 into a UUID temp first,
            // then atomically swap it in — a kill/timeout/OOM mid-run must not truncate a
            // previously-good _x4.png (the ×2 path was already atomic via its own temp).
            let fm = FileManager.default
            let tmp = dir.appendingPathComponent("\(stem)_x4_tmp_\(UUID().uuidString).png")
            defer { try? fm.removeItem(at: tmp) }
            try run(binary, ["-i", input.path, "-o", tmp.path, "-s", "4", "-n", "realesrgan-x4plus"])
            if scale == 4 {
                if fm.fileExists(atPath: outURL.path) { _ = try fm.replaceItemAt(outURL, withItemAt: tmp) }
                else { try fm.moveItem(at: tmp, to: outURL) }
            } else {
                try downscale(tmp, to: outURL, factor: Double(scale) / 4.0)
            }
        }.value
        guard FileManager.default.fileExists(atPath: outURL.path) else { throw UpscaleError.noOutput }
        return outURL
    }

    private static func verify(zip: URL) throws {
        let data = try Data(contentsOf: zip)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == releaseZipSHA256 else {
            try? FileManager.default.removeItem(at: zip)
            throw UpscaleError.checksumMismatch
        }
    }

    /// High-quality CoreGraphics resize (used to derive ×2 from the native ×4 output).
    private static func downscale(_ src: URL, to dst: URL, factor: Double) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw UpscaleError.noOutput
        }
        let w = max(1, Int(Double(img.width) * factor))
        let h = max(1, Int(Double(img.height) * factor))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw UpscaleError.noOutput
        }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw UpscaleError.noOutput }
        _ = try ImageSaver.savePNG(out, into: dst.deletingLastPathComponent(), name: dst.lastPathComponent)
    }

    private static func install(from zip: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: toolDir, withIntermediateDirectories: true)
        try run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-oq", zip.path, "-d", toolDir.path])
        // We only ever run realesrgan-x4plus — drop the anime model variants (~13 MB).
        let modelsDir = toolDir.appendingPathComponent("models")
        if let files = try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil) {
            for f in files where !f.lastPathComponent.hasPrefix("realesrgan-x4plus.") {
                try? fm.removeItem(at: f)
            }
        }
        // Strip the quarantine flag or Gatekeeper refuses to exec the downloaded binary.
        try? run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-cr", toolDir.path])
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        guard isInstalled else { throw UpscaleError.installFailed }
    }

    private static func run(_ executable: URL, _ args: [String], timeout: TimeInterval = 300) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        // realesrgan needs no secrets. The engine setenv's HF_TOKEN into our own process env,
        // which a spawned child inherits by default — strip the token vars from the child.
        var env = ProcessInfo.processInfo.environment
        for key in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_TOKEN", "HF_API_TOKEN"] {
            env.removeValue(forKey: key)
        }
        p.environment = env
        p.currentDirectoryURL = toolDir   // the tool finds its models/ next to the binary
        p.standardOutput = FileHandle.nullDevice
        // stderr goes to a temp FILE, not a Pipe (an undrained pipe can deadlock the child);
        // it's read back only on failure so errors finally carry diagnostics.
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upscale_err_\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try? FileHandle(forWritingTo: errURL)
        p.standardError = errHandle ?? FileHandle.nullDevice
        defer {
            try? errHandle?.close()
            try? FileManager.default.removeItem(at: errURL)
        }

        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        processLock.lock(); currentProcess = p; processLock.unlock()
        defer { processLock.lock(); currentProcess = nil; processLock.unlock() }

        try p.run()
        // A wedged child used to block this thread forever and latch isUpscaling until
        // relaunch — give it a generous ceiling, then terminate (SIGKILL as last resort).
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 5)
            }
            throw UpscaleError.timedOut
        }
        guard p.terminationStatus == 0 else {
            let tail = (try? String(contentsOf: errURL, encoding: .utf8))?
                .split(separator: "\n").suffix(3).joined(separator: " · ") ?? ""
            throw UpscaleError.toolFailed(Int(p.terminationStatus), tail)
        }
    }

    enum UpscaleError: LocalizedError {
        case installFailed
        case checksumMismatch
        case toolFailed(Int, String)
        case noOutput
        case timedOut
        case busy

        var errorDescription: String? {
            switch self {
            case .busy: return "Another upscale is already running — wait for it to finish."
            case .installFailed: return "Upscaler install failed."
            case .checksumMismatch:
                return "Upscaler download didn't match the expected checksum — install aborted. Try again later."
            case .toolFailed(let code, let detail):
                return detail.isEmpty ? "Upscaler exited with code \(code)."
                                      : "Upscaler exited with code \(code): \(detail)"
            case .noOutput: return "Upscaler produced no output file."
            case .timedOut: return "Upscaler didn't finish in time and was stopped."
            }
        }
    }
}
