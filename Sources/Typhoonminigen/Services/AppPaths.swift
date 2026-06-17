import Foundation

/// Single source of truth for every on-disk location the app uses.
///
/// Storage layout:
/// ```
/// ~/Library/Application Support/Typhoonminigen/
///   ├─ Models/           ← engine model cache (shared with the flux2 CLI)
///   ├─ Images/           ← generated PNGs
///   ├─ LoRAs/            ← *.safetensors adapters
///   └─ generations.json  ← gallery index
/// ~/Library/Caches/Typhoonminigen/
///   └─ thumbnails/       ← gallery thumbnails (safe to clear; never touches Models)
/// ~/Library/Logs/Typhoonminigen/
///   └─ typhoonminigen.log   ← rotating app log
/// ```
enum AppPaths {
    static let appName = "Typhoonminigen"

    private static var library: URL {
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    // MARK: Application Support

    static var appSupport: URL {
        library.appendingPathComponent("Application Support/\(appName)", isDirectory: true)
    }

    /// Engine model cache. MUST match what we pass to the engine's
    /// `ModelRegistry.customModelsDirectory` so the app reuses downloaded weights.
    static var models: URL { appSupport.appendingPathComponent("Models", isDirectory: true) }

    static var images: URL { appSupport.appendingPathComponent("Images", isDirectory: true) }
    static var loras: URL { appSupport.appendingPathComponent("LoRAs", isDirectory: true) }

    static var generationsIndex: URL { appSupport.appendingPathComponent("generations.json") }

    // MARK: Caches

    static var caches: URL {
        library.appendingPathComponent("Caches/\(appName)", isDirectory: true)
    }
    static var thumbnails: URL { caches.appendingPathComponent("thumbnails", isDirectory: true) }

    // MARK: Logs

    static var logs: URL {
        library.appendingPathComponent("Logs/\(appName)", isDirectory: true)
    }
    static var logFile: URL { logs.appendingPathComponent("typhoonminigen.log") }

    // MARK: Bootstrap

    /// Creates all directories. Call once at launch before any storage use.
    static func bootstrap() {
        for dir in [appSupport, models, images, loras, caches, thumbnails, logs] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
