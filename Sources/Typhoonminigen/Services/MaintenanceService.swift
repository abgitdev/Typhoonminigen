import Foundation
import MLX

/// Logs + cache cleanup. Never touches the Models directory (that is the Model-management
/// feature's job) so a cache-clear can't cost a multi-GB re-download.
enum MaintenanceService {
    /// Clear the app log file. Returns bytes freed AND bytes still on disk afterwards.
    static func clearLogs() -> (freed: Int64, remaining: Int64) {
        AppLog.shared.clear()
    }

    /// Clear caches (everything under AppPaths.caches) + the MLX GPU buffer pool.
    /// Returns bytes freed on disk.
    static func clearCaches() -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        if let items = try? fm.contentsOfDirectory(at: AppPaths.caches, includingPropertiesForKeys: nil) {
            for item in items {
                let sz = directorySize(item)
                // Count bytes as freed ONLY when the remove actually succeeds — a locked/undeletable
                // file must not be reported as reclaimed (matches clearLogs' honest accounting).
                do { try fm.removeItem(at: item); freed += sz } catch { }
            }
        }
        return freed   // NB: the MLX pool is flushed separately via clearMLXPool(), re-gated on idle.
    }

    /// Flush the MLX GPU buffer pool. Kept OUT of clearCaches()/removeAllData() (which run their
    /// file walk off-actor) so the caller can re-check "not busy" right before it — flushing the
    /// pool while a generation is in flight could corrupt its GPU buffers (a TOCTOU race).
    static func clearMLXPool() { Memory.clearCache() }

    /// Nuke EVERY trace of the app's data on disk — models + encoders, gallery images, LoRAs,
    /// presets, caches, logs, AND the shared HuggingFace download cache. For the user to run
    /// BEFORE trashing the .app, since macOS can't clean a trashed app's files. Returns bytes freed.
    static func removeAllData() -> Int64 {
        let fm = FileManager.default
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let home = fm.homeDirectoryForCurrentUser
        let bid = "com.personal.typhoonminigen"
        let targets: [URL] = [
            AppPaths.appSupport,                                        // Models, Images, LoRAs, generations.json, presets
            AppPaths.caches,                                            // thumbnails
            lib.appendingPathComponent("Logs/Typhoonminigen", isDirectory: true),
            home.appendingPathComponent(".cache/huggingface", isDirectory: true),
            lib.appendingPathComponent("Caches/\(bid)", isDirectory: true),
            lib.appendingPathComponent("HTTPStorages/\(bid)", isDirectory: true),
        ]
        var freed: Int64 = 0
        var seen = Set<String>()
        for url in targets where seen.insert(url.standardizedFileURL.path).inserted {
            guard fm.fileExists(atPath: url.path) else { continue }
            let sz = directorySize(url)
            // Count bytes only when the remove actually succeeds — don't bill a tree as "freed"
            // (and claim "nothing is left behind") if the delete failed (matches clearCaches/clearLogs).
            do { try fm.removeItem(at: url); freed += sz } catch { }
        }
        // The Keychain HF token + ALL the app's UserDefaults are NOT files — they survive a disk
        // wipe, so "Remove all data" (sold as a clean uninstall: "nothing is left behind") must
        // clear the secret credential AND every stored setting/flag, not just the legacy token key.
        HFToken.delete()
        // Clear the WHOLE settings domain. Fall back to the hardcoded bundle id when
        // Bundle.main.bundleIdentifier is nil (a non-bundled `swift run` dev binary) so even a dev
        // run wipes everything, not just the legacy token key.
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? bid)
        // No Memory.clearCache() here: the caller (SystemViewModel.removeAllData) already unloaded the
        // model via engine.freeMemory(), which flushed the pool while holding the engine actor.
        return freed
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let f as URL in en {
                let sz = (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
                total += Int64(sz)
            }
        }
        if total == 0 {
            let sz = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(sz)
        }
        return total
    }
}
