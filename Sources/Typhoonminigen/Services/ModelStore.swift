import Foundation
import CryptoKit
import Flux2Core
import FluxTextEncoders

/// An auxiliary on-disk model component (encoder / VAE / VLM). "Delete model" only reclaims
/// the transformer — these rows make the other ~11 GB visible and manageable (audit finding).
struct AuxComponent: Identifiable, Sendable {
    let id: String       // relative path under the app's Models dir
    let title: String
    let note: String     // role + what happens after delete
    let bytes: Int64
}

enum ModelStoreError: LocalizedError {
    case integrityMismatch(expected: String, actual: String)
    case pinnedFileMissing

    var errorDescription: String? {
        switch self {
        case .integrityMismatch(let expected, let actual):
            return "Downloaded weights failed the integrity check (SHA-256 \(actual.prefix(12))… ≠ pinned \(expected.prefix(12))…). The file was removed — try again; if it repeats, the upstream repo has changed and needs re-review."
        case .pinnedFileMissing:
            return "The downloaded model is missing its pinned weight file — the upstream repo layout has changed and needs re-review before use."
        }
    }
}

/// Wraps the engine's model downloader for the Klein transformers:
/// list state + size, download (with progress + integrity pin + encoder), delete to reclaim space.
actor ModelStore {
    /// Everything the engine stores next to the transformer. All re-download automatically
    /// and tokenlessly when next needed, so deleting any of them is safe — just costs a
    /// re-download.
    private static let auxDefs: [(rel: String, title: String, note: String)] = [
        ("lmstudio-community/Qwen3-8B-MLX-8bit",
         "Qwen3-8B text encoder (Klein 9B)",
         "Required for every Klein 9B generation. Re-downloads automatically (~8 GB, no token)."),
        ("lmstudio-community/Qwen3-4B-MLX-8bit",
         "Qwen3-4B text encoder (Klein 4B)",
         "Required for every Klein 4B generation. Re-downloads automatically (~4 GB, no token)."),
        // The engine silently PREFERS an existing 4-bit Qwen3-4B over fetching the 8-bit —
        // list it so the disk accounting never hides a ~2 GB directory.
        ("lmstudio-community/Qwen3-4B-MLX-4bit",
         "Qwen3-4B text encoder · 4-bit (Klein 4B)",
         "Lighter encoder variant — when present, Klein 4B uses it instead of the 8-bit one."),
        ("black-forest-labs/FLUX.2-klein-4B-vae",
         "Shared VAE (latents → pixels)",
         "Required for every generation — BOTH Klein tiers decode through it (the \u{201C}klein-4B\u{201D} name is just the repo BFL hosts it in). Re-downloads automatically (~160 MB, no token)."),
        ("mlx-community/Qwen3.5-4B-MLX-4bit",
         "Qwen3.5-VLM (Describe with AI)",
         "Only needed for Describe. Re-downloads on next use (~3 GB, no token)."),
    ]

    /// The components currently present on disk, with real sizes.
    func auxComponents() -> [AuxComponent] {
        // Dangling symlink-imports (original moved/unmounted) must not list as installed.
        ModelImportService.sweepDanglingLinks(under: AppPaths.models)
        return Self.auxDefs.compactMap { def in
            let url = AppPaths.models.appendingPathComponent(def.rel, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return AuxComponent(id: def.rel, title: def.title, note: def.note,
                                bytes: Self.directorySize(url))
        }
    }

    /// Delete one auxiliary component. Returns bytes reclaimed, or nil when the target was
    /// a symlink-import — removing the link frees ~nothing, so no freed-bytes figure.
    func deleteAux(_ id: String) throws -> Int64? {
        // Only known component paths — never an arbitrary rm inside Models/.
        guard Self.auxDefs.contains(where: { $0.rel == id }) else { return 0 }
        let url = AppPaths.models.appendingPathComponent(id, isDirectory: true)
        if Self.isSymlink(url) {
            try FileManager.default.removeItem(at: url)  // removes the link, never the originals
            return nil
        }
        let size = Self.directorySize(url)
        try FileManager.default.removeItem(at: url)
        return size
    }

    func catalog() -> [ModelInfo] {
        // Dangling symlink-imports (original moved/unmounted) must not list as installed.
        ModelImportService.sweepDanglingLinks(under: AppPaths.models)
        return ModelTier.allCases.map { tier in
            let comp = ModelRegistry.ModelComponent.transformer(tier.transformerVariant)
            let downloaded = Flux2ModelDownloader.isDownloaded(comp)
            return ModelInfo(
                id: tier.rawValue,
                tier: tier,
                title: tier.displayName,
                estimatedSizeGB: tier.transformerVariant.estimatedSizeGB,
                isGated: tier.transformerVariant.isGated,
                isDownloaded: downloaded,
                isEncoderDownloaded: tier.isEncoderDownloaded,
                downloadedBytes: downloaded ? sizeOf(comp) : 0,
                license: tier.license
            )
        }
    }

    func download(
        tier: ModelTier,
        hfToken: String?,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let downloader = Flux2ModelDownloader(hfToken: hfToken)
        let comp = ModelRegistry.ModelComponent.transformer(tier.transformerVariant)
        // NB 4B is one 3.9 GB safetensors and engine progress is per-file — the bar sits
        // still for most of the transfer; ModelRow shows a persistent caption for that.
        _ = try await downloader.download(comp, progress: onProgress)
    }

    /// Pre-download the tier's Qwen3 text encoder (tokenless). Without this the engine
    /// fetches it lazily and SILENTLY inside the first generation's Phase 1 — a multi-GB
    /// stall with no progress UI. Fast-returns if already on disk.
    func downloadEncoder(
        tier: ModelTier,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let downloader = TextEncoderModelDownloader()
        _ = try await downloader.downloadQwen3(variant: tier.encoderVariant) { p, m in
            onProgress(p, m)
        }
    }

    // MARK: Integrity pin

    /// SHA-256 pins for transformers fetched from COMMUNITY repos. The engine downloads
    /// from the mutable `main` branch and verifies file PRESENCE only — the repo owner
    /// could swap weights at any time (v0.38 policy: pin what we verified, like the
    /// Real-ESRGAN binary). BFL's own gated repos are deliberately not pinned.
    private static let pinnedTransformerSHA256: [ModelTier: String] = [
        // aydin99/FLUX.2-klein-4B-int8 · diffusion_pytorch_model.safetensors (3,877,645,084 bytes)
        // Verified on download 2026-06-10; size byte-matched the HF API listing.
        .klein4B: "fb6e95fd62f2af89151cef9f22a99da842a0968ecec35bdeaf8d58403ad14f8d",
    ]

    /// Throws (and removes the directory) when a pinned tier's main weight file doesn't
    /// match its recorded hash. No-op for unpinned tiers or missing files.
    func verifyTransformerIntegrity(tier: ModelTier) throws {
        guard let expected = Self.pinnedTransformerSHA256[tier],
              expected.count == 64 else { return }   // unpinned tier → nothing to check
        let comp = ModelRegistry.ModelComponent.transformer(tier.transformerVariant)
        // A pinned tier whose expected file is MISSING is a failure, not a skip — an
        // upstream rename/reshard would otherwise silently disarm the pin forever.
        guard let dir = Flux2ModelDownloader.findModelPath(for: comp) else {
            throw ModelStoreError.pinnedFileMissing
        }
        let file = dir.appendingPathComponent("diffusion_pytorch_model.safetensors")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ModelStoreError.pinnedFileMissing
        }
        let actual = try Self.sha256(of: file)
        guard actual == expected else {
            try? FileManager.default.removeItem(at: dir)
            throw ModelStoreError.integrityMismatch(expected: expected, actual: actual)
        }
        AppLog.info("Transformer integrity OK (\(tier.shortName), SHA-256 \(actual.prefix(12))…)")
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // The SHA-256 pin is the ONLY integrity gate, so the hash is deliberately NOT
            // cancellable: a Cancel landing mid-hash must not abort verification and leave a
            // complete-but-UNVERIFIED transformer on disk (nothing re-verifies it afterwards, and
            // the generate path loads it unchecked). The pass is only seconds for the pinned 4B
            // weight; the download caller honors the cancel right AFTER verify returns. (Throwing
            // read API — readData raises uncatchable ObjC exceptions on I/O errors; a genuine I/O
            // error still throws and is reported as a real failure, not as a cancel.)
            guard let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 8 * 1024 * 1024) }),
                  !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Delete a tier's transformer. Returns bytes reclaimed, or nil when the target was
    /// a symlink-import — removing the link frees ~nothing, so no freed-bytes figure.
    func delete(tier: ModelTier) throws -> Int64? {
        let comp = ModelRegistry.ModelComponent.transformer(tier.transformerVariant)
        // findModelPath keeps the unresolved URL, so removeItem deletes only the link.
        if let path = Flux2ModelDownloader.findModelPath(for: comp), Self.isSymlink(path) {
            try FileManager.default.removeItem(at: path)
            return nil
        }
        let before = Flux2ModelDownloader.isDownloaded(comp) ? sizeOf(comp) : 0
        try Flux2ModelDownloader.delete(comp)
        return before
    }

    /// attributesOfItem does NOT follow links — exactly what the delete paths need.
    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func sizeOf(_ comp: ModelRegistry.ModelComponent) -> Int64 {
        guard let path = Flux2ModelDownloader.findModelPath(for: comp) else { return 0 }
        return Self.directorySize(path)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        // Imported components may be SYMLINKS to the user's originals — an enumerator
        // rooted at a link yields zero items, showing 0 B. Resolve first; delete paths
        // intentionally keep the unresolved URL (removing a link must not touch originals).
        let resolved = url.resolvingSymlinksInPath()
        if let en = fm.enumerator(at: resolved, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let f as URL in en {
                total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }
}
