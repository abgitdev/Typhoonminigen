import SwiftUI
import Observation
import AppKit

@MainActor
@Observable
final class ModelsViewModel {
    var models: [ModelInfo] = []
    var auxComponents: [AuxComponent] = []
    var hfToken: String = ""
    var downloadingTier: ModelTier? = nil
    var downloadProgress: Double = 0
    var downloadMessage: String = ""
    var lastAction: ActionMessage? = nil
    var loadedTier: ModelTier? = nil    // which tier is resident in RAM (nil = none)
    var pendingImport: [FoundComponent]? = nil  // non-nil = the import confirmation dialog is up
    var importing: Bool = false
    /// Bytes in the shared HuggingFace download cache (~/.cache/huggingface). Some weights
    /// land there via HF Hub and the per-model delete doesn't touch it — surfaced so the user
    /// can see and clear it from the Models tab instead of hunting in Terminal.
    var hfCacheBytes: Int64 = 0

    private let store = ModelStore()
    private let engine: FluxEngine
    private var downloadTask: Task<Void, Never>? = nil

    /// Fired after unload/download/delete so the header model chip (driven by
    /// GenerateViewModel) re-syncs immediately instead of waiting for a tab switch.
    @ObservationIgnored var onModelStateChange: (() -> Void)? = nil

    /// A token is actually PERSISTED (Keychain / env) — drives the "saved" pills. The text
    /// field alone must not: typing used to light "connected" before anything was stored.
    var tokenSaved: Bool = false

    init(engine: FluxEngine) {
        self.engine = engine
        hfToken = HFToken.current(for: .klein9B) ?? ""  // 9B = the only gated tier
        tokenSaved = !hfToken.isEmpty
    }

    var hasToken: Bool { !hfToken.trimmingCharacters(in: .whitespaces).isEmpty }

    func reload() {
        Task { @MainActor in
            self.models = await store.catalog()
            self.auxComponents = await store.auxComponents()
            self.loadedTier = await engine.loadedTier
            self.hfCacheBytes = await Self.directorySize(Self.hfCacheURL)
        }
    }

    /// Delete an auxiliary component (encoder / VAE / VLM). All of them re-download
    /// automatically when next needed, so this is always recoverable.
    func deleteAux(_ comp: AuxComponent) {
        Task { @MainActor in
            guard downloadingTier == nil else {
                self.lastAction = .error("Can't delete while a download is running.")
                return
            }
            guard !importing else {
                self.lastAction = .error("Can't delete — wait for the import to finish.")
                return
            }
            // isWorking covers the cold-load window too (busy==true, loadedTier still nil) —
            // deleting an encoder/VAE the engine is mid-loading would crash the generation.
            if await engine.isWorking {
                self.lastAction = .error("Can't delete — the engine is busy. Try again in a moment.")
                return
            }
            if await engine.loadedTier != nil {
                self.lastAction = .error("Can't delete — a model is in memory. Unload it first.")
                return
            }
            do {
                if let freed = try await store.deleteAux(comp.id) {
                    self.lastAction = .ok("\(comp.title) deleted — freed \(ByteFormat.string(freed)).")
                } else {
                    self.lastAction = .ok("\(comp.title): link removed — the original files were not touched.")
                }
                AppLog.info("Component deleted: \(comp.title)")
            } catch {
                self.lastAction = .error("Delete error: \(error.localizedDescription)")
            }
            self.auxComponents = await store.auxComponents()
            // Deleting the selected tier's encoder must reach the canvas CTA flags
            // (modelMissing/encoderMissing) like every other mutation here does.
            self.onModelStateChange?()
        }
    }

    /// Unload the resident model (Models row "Unload").
    func unload() {
        Task { @MainActor in
            let freed = await engine.freeMemory()
            self.loadedTier = await engine.loadedTier
            self.lastAction = freed ? .ok("Model unloaded from memory.")
                                    : .error("Generation in progress — can't unload right now.")
            self.onModelStateChange?()
        }
    }

    // MARK: Import existing weights

    /// Survives the dialog binding flipping to false — confirmationDialog clears
    /// isPresented (which nils pendingImport) BEFORE running the chosen button's action.
    @ObservationIgnored private var stagedImport: [FoundComponent] = []

    /// Pick a folder of MLX weights and scan it for recognizable components.
    func pickAndScanImportFolder() {
        guard !importing else { return }
        guard downloadingTier == nil else {
            lastAction = .error("Can't import while a download is running — wait for it to finish.")
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder with MLX model weights (the model directory itself, or a parent that contains several)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true   // gate downloads / quit-without-confirm while we scan the folder
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) {
                ModelImportService.scan(folder: url)
            }.value
            self.importing = false   // scan done — the dialog now drives; performImport re-gates the install
            if found.isEmpty {
                self.lastAction = .error("No MLX components recognized in \u{201C}\(url.lastPathComponent)\u{201D} — the folder must contain complete MLX-format weights (config.json or model_index.json inside). ComfyUI single-file checkpoints are not supported.")
            } else {
                self.stagedImport = found
                self.pendingImport = found
            }
        }
    }

    func cancelImport() {
        pendingImport = nil
        stagedImport = []
    }

    /// Install everything found (skipping already-installed components), then reload.
    func performImport(mode: ImportMode) {
        let items = pendingImport ?? stagedImport
        pendingImport = nil
        stagedImport = []
        guard !items.isEmpty, !importing else { return }
        guard downloadingTier == nil else {
            lastAction = .error("Can't import while a download is running — wait for it to finish.")
            return
        }
        let todo = items.filter { !$0.alreadyInstalled }
        guard !todo.isEmpty else {
            lastAction = .ok("Nothing to import — every found component is already installed.")
            return
        }
        importing = true
        lastAction = nil
        Task { @MainActor in
            let (okCount, failures) = await Task.detached(priority: .userInitiated) { () -> (Int, [String]) in
                var ok = 0
                var fails: [String] = []
                for item in todo {
                    do {
                        try ModelImportService.install(item, mode: mode)
                        ok += 1
                    } catch {
                        fails.append("\(item.component.displayName): \(error.localizedDescription)")
                    }
                }
                return (ok, fails)
            }.value
            let skipped = items.count - todo.count
            let verb = mode == .copy ? "copied" : "linked"
            if failures.isEmpty {
                var text = "Imported \(okCount) component\(okCount == 1 ? "" : "s") (\(verb))."
                if skipped > 0 { text += " Skipped \(skipped) already installed." }
                self.lastAction = .ok(text)
                AppLog.info("Weights import: \(okCount) \(verb), \(skipped) skipped")
            } else {
                self.lastAction = .error("Import finished with errors — \(okCount) ok, \(failures.count) failed. \(failures.joined(separator: " "))")
                AppLog.error("Weights import: \(failures.joined(separator: "; "))")
            }
            self.importing = false
            self.models = await store.catalog()
            self.auxComponents = await store.auxComponents()
            self.onModelStateChange?()
        }
    }

    /// Transformer (+ encoder when it still needs downloading) + headroom, in bytes
    /// (4B ≈ 3.9 + 4.0 GB; 9B ≈ 18 + 8.1 GB). The encoder share is skipped when that
    /// tier's Qwen3 is already on disk — demanding the full constant blocked retries
    /// that would in fact succeed.
    private static func requiredDiskBytes(for tier: ModelTier) -> Int64 {
        let transformerPlusHeadroom: Int64 = tier == .klein9B ? 19 : 5
        let encoder: Int64 = tier.isEncoderDownloaded ? 0 : (tier == .klein9B ? 9 : 5)
        return (transformerPlusHeadroom + encoder) * 1_073_741_824
    }

    /// Encoder-only requirement for the "Get encoder" recovery path, incl. headroom.
    private static func encoderDiskBytes(for tier: ModelTier) -> Int64 {
        (tier == .klein9B ? 9 : 5) * 1_073_741_824
    }

    /// Free space the way Finder counts it (importantUsage = purgeable space macOS frees
    /// on demand for large writes — plain capacity under-reports by tens of GB when Time
    /// Machine snapshots exist, falsely blocking legitimate downloads). One XPC call per
    /// button click, NOT the 2 Hz telemetry path that had to avoid this key.
    /// nil = couldn't stat; don't block on that.
    private static func freeDiskBytes() -> Int64? {
        let values = try? AppPaths.models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func download(_ tier: ModelTier) {
        guard downloadingTier == nil else { return }
        guard !importing else {
            lastAction = .error("Can't download — wait for the import to finish.")
            return
        }
        // Pre-flight 1: a gated download without a token fails minutes in with a raw HTTP
        // error — catch it before any bytes move.
        if tier.isGated, hfToken.trimmingCharacters(in: .whitespaces).isEmpty {
            lastAction = .error("Klein 9B is gated — paste your HuggingFace token above and accept the model license on its HuggingFace page first.")
            return
        }
        // Pre-flight 2: don't start a multi-GB download that's guaranteed to fill the disk.
        let needed = Self.requiredDiskBytes(for: tier)
        if let free = Self.freeDiskBytes(), free < needed {
            lastAction = .error("Not enough disk space: \(tier.shortName) needs ~\(ByteFormat.string(needed)) free (download + headroom), only \(ByteFormat.string(free)) available.")
            return
        }
        // Clear any stale message from a prior attempt BEFORE the token-save step, so a Keychain
        // save-failure error raised just below survives to be shown (it used to be wiped a few lines
        // down by `lastAction = nil`, so the user never saw it).
        lastAction = nil
        if tier.isGated, !hfToken.isEmpty {
            // Only RAISE the saved pill on a real Keychain success; a write failure must not flip
            // the pill to "not saved" (and silently proceed) — surface it. The download still runs
            // with the in-memory token below.
            if HFToken.save(hfToken) {
                tokenSaved = true
            } else {
                lastAction = .error("Couldn't save the token to the Keychain — using it for this download only.")
            }
        }
        downloadingTier = tier
        downloadProgress = 0
        downloadMessage = "Preparing…"
        let token = tier.isGated ? (hfToken.isEmpty ? nil : hfToken) : nil

        downloadTask = Task { @MainActor in
            do {
                // Phase 1 — transformer (the big weight): 0…70% of the bar.
                try await store.download(tier: tier, hfToken: token) { p, m in
                    Task { @MainActor in
                        self.downloadProgress = p * 0.7
                        self.downloadMessage = m
                    }
                }
                // Phase 2 — integrity pin for community repos (seconds, streaming SHA-256).
                // Verify BEFORE honoring a cancel: a cancel landing between download and verify
                // must not leave an UNVERIFIED-but-complete transformer that the generate path
                // would then load unchecked. Verify is seconds and not cancellable.
                self.downloadMessage = "Verifying file integrity…"
                try await store.verifyTransformerIntegrity(tier: tier)
                try Task.checkCancellation()   // now honor cancel — skip the (resumable) encoder phase
                // Phase 3 — the tier's Qwen3 encoder, pre-downloaded HERE so the first
                // generation doesn't stall on the engine's silent lazy download: 70…100%.
                try await store.downloadEncoder(tier: tier) { p, m in
                    Task { @MainActor in
                        self.downloadProgress = 0.7 + p * 0.3
                        self.downloadMessage = "Encoder: \(m)"
                    }
                }
                self.lastAction = .ok("\(tier.displayName) downloaded.")
                AppLog.info("Model downloaded: \(tier.displayName)")
            } catch {
                // URLSession surfaces task cancellation as URLError(.cancelled), not
                // CancellationError — and mid-transfer is where cancel almost always lands.
                // Classify by the error's SHAPE, not a bare `Task.isCancelled`: the SHA verify is
                // now non-cancellable, so a genuine read failure during "Verifying…" can coincide
                // with a set cancel flag — it must surface as a real "Download error", not be
                // relabeled as a benign cancel. Every real cancel path throws a cancellation-shaped
                // error (URLError.cancelled in the transfers, CancellationError from the post-verify
                // checkCancellation), so this loses no cancel detection.
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.lastAction = .ok("Download cancelled. Completed components are kept; an interrupted transformer re-downloads from the start.")
                    AppLog.info("Model download cancelled: \(tier.displayName)")
                } else {
                    self.lastAction = .error("Download error: \(error.localizedDescription)")
                    AppLog.error("Model download: \(error.localizedDescription)")
                }
            }
            self.downloadingTier = nil
            self.downloadTask = nil
            self.models = await store.catalog()
            self.auxComponents = await store.auxComponents()
            self.onModelStateChange?()
        }
    }

    /// Abort the in-flight download (the Task cancellation propagates into URLSession).
    func cancelDownload() {
        guard downloadTask != nil else { return }
        downloadMessage = "Cancelling…"
        downloadTask?.cancel()
    }

    /// Re-run only the encoder phase — the recovery path when a download was cancelled
    /// after the transformer finished (the row then shows "on disk" with no Download button).
    func downloadEncoder(_ tier: ModelTier) {
        guard downloadingTier == nil else { return }
        guard !importing else {
            lastAction = .error("Can't download — wait for the import to finish.")
            return
        }
        // Same disk pre-flight as the full download — this recovery path is reached
        // exactly when space tends to be tight (cancelled downloads, freed components).
        let needed = Self.encoderDiskBytes(for: tier)
        if let free = Self.freeDiskBytes(), free < needed {
            lastAction = .error("Not enough disk space: the \(tier.shortName) encoder needs ~\(ByteFormat.string(needed)) free, only \(ByteFormat.string(free)) available.")
            return
        }
        downloadingTier = tier
        downloadProgress = 0
        downloadMessage = "Encoder: preparing…"
        lastAction = nil
        downloadTask = Task { @MainActor in
            do {
                try await store.downloadEncoder(tier: tier) { p, m in
                    Task { @MainActor in
                        self.downloadProgress = p
                        self.downloadMessage = "Encoder: \(m)"
                    }
                }
                self.lastAction = .ok("\(tier.shortName) text encoder downloaded.")
                AppLog.info("Encoder downloaded: \(tier.shortName)")
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                    self.lastAction = .ok("Download cancelled. Already-fetched files are reused next time.")
                } else {
                    self.lastAction = .error("Download error: \(error.localizedDescription)")
                    AppLog.error("Encoder download: \(error.localizedDescription)")
                }
            }
            self.downloadingTier = nil
            self.downloadTask = nil
            self.models = await store.catalog()
            self.auxComponents = await store.auxComponents()
            self.onModelStateChange?()
        }
    }

    func persistToken() {
        let ok = HFToken.save(hfToken)  // S-4: Keychain instead of plaintext UserDefaults
        tokenSaved = hasToken && ok     // empty save = delete (always succeeds)
        if !hasToken {
            lastAction = .ok("Token removed.")
        } else if ok {
            lastAction = .ok("Token saved to the Keychain.")
        } else {
            lastAction = .error("Couldn't save the token to the Keychain — please try again.")
        }
    }

    func delete(_ tier: ModelTier) {
        Task { @MainActor in
            // Never delete a model that's being downloaded right now.
            if self.downloadingTier == tier {
                self.lastAction = .error("Can't delete — the model is downloading.")
                return
            }
            guard !self.importing else {
                self.lastAction = .error("Can't delete — wait for the import to finish.")
                return
            }
            // A generation/cold-load in flight may be reading this tier's files right now
            // (loadedTier is still nil during the load), so block on the real busy signal.
            if await engine.isWorking {
                self.lastAction = .error("Can't delete — the engine is busy. Try again in a moment.")
                return
            }
            // Never delete the model that's currently resident in memory.
            if await engine.loadedTier == tier {
                self.lastAction = .error("Can't delete — the model is in memory. Unload it first (System tab).")
                return
            }
            do {
                if let freed = try await store.delete(tier: tier) {
                    self.lastAction = .ok("\(tier.displayName) deleted — freed \(ByteFormat.string(freed)).")
                } else {
                    self.lastAction = .ok("\(tier.displayName): link removed — the original files were not touched.")
                }
                AppLog.info("Model deleted: \(tier.displayName)")
            } catch {
                self.lastAction = .error("Delete error: \(error.localizedDescription)")
            }
            self.models = await store.catalog()
            self.onModelStateChange?()
        }
    }

    // MARK: Storage locations (reveal / clear)

    /// The shared HuggingFace Hub cache (~/.cache/huggingface). Some weights download here
    /// rather than into AppPaths.models, so the per-model "Delete" can't reach them.
    static var hfCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface", isDirectory: true)
    }

    func revealModelsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.models])
    }

    func revealHFCache() {
        let url = Self.hfCacheURL
        let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// Delete the whole HuggingFace cache. These are re-downloadable model files; the cache
    /// is shared with any other HF tool on this Mac (the UI warns about that).
    func clearHFCache() {
        Task { @MainActor in
            guard downloadingTier == nil else {
                self.lastAction = .error("Can't clear the cache while a download is running.")
                return
            }
            let url = Self.hfCacheURL
            let freed = self.hfCacheBytes
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                self.lastAction = .ok("HuggingFace cache cleared — freed \(ByteFormat.string(freed)).")
                AppLog.info("HuggingFace cache cleared: \(ByteFormat.string(freed))")
            } catch {
                self.lastAction = .error("Couldn't clear the HuggingFace cache: \(error.localizedDescription)")
            }
            self.hfCacheBytes = await Self.directorySize(Self.hfCacheURL)
        }
    }

    /// Sum allocated file sizes under a directory, off the main thread (missing dir → 0).
    private static func directorySize(_ url: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path),
                  let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
            var total: Int64 = 0
            while let f = en.nextObject() as? URL {
                let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
            return total
        }.value
    }
}
