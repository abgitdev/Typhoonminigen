import Foundation
import CoreGraphics
import Flux2Core
import MLX

/// Everything needed for one text-to-image generation. Sendable so it can cross
/// the actor boundary.
struct GenerationRequest: Sendable {
    var prompt: String
    var tier: ModelTier
    var quant: Flux2QuantizationConfig
    var width: Int = 1024
    var height: Int = 1024
    var steps: Int
    var guidance: Float
    var seed: UInt64?
    /// LoRAs to fuse, in slot order (≤2 by app policy; deltas sum, so order is cosmetic).
    var loras: [LoRAUse] = []
    var upsamplePrompt: Bool = false
    // I2I metadata (paths stored in the gallery record; actual CGImages passed separately
    // to generate()). Up to 3 references — the engine pipeline rejects more.
    var referenceImagePaths: [String]? = nil
}

enum FluxEngineError: LocalizedError {
    case notLoaded
    case busy

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Model not loaded."
        case .busy: return "Engine is busy generating."
        }
    }
}

/// The heart of the app: a single long-lived `Flux2Pipeline` wrapped in an actor.
///
/// Being an actor serializes generation, tier-switching, LoRA loading and memory
/// freeing for free — you can never generate while switching tiers. Holds at most
/// ONE model resident (32 GB budget); switching tiers unloads the previous one.
actor FluxEngine {
    private var pipeline: Flux2Pipeline?
    private(set) var loadedTier: ModelTier?
    private(set) var loadedQuant: Flux2QuantizationConfig?
    /// Fusion identity: the requested LoRAUse plus a content stamp (size + mtime), so
    /// overwriting a .safetensors with a retrained file of the same name is detected and
    /// forces a clean weight reload. Kept out of LoRAUse so gallery records stay
    /// pure path/name/scale.
    private struct FusedLoRA: Hashable {
        let use: LoRAUse
        let stamp: String
    }
    private static func fileStamp(_ path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)-\(mtime)"
    }

    /// The LoRA set currently FUSED into the resident transformer weights.
    private var appliedLoRAs: [FusedLoRA] = []
    private var busy = false   // true during a generation; blocks teardown (actor-reentrancy guard)
    /// True while a VLM Describe is holding the process-global MLX buffer pool. The VLM runs
    /// OUTSIDE this actor (via FluxTextEncoders.shared), so the VM sets this around describe;
    /// freeMemory() honors it so an idle/manual/cross-tab unload can't clear the pool mid-describe.
    private var describing = false

    var isLoaded: Bool { pipeline != nil }
    /// "Something is using the global MLX pool" — a generation (incl. its cold load) OR a VLM
    /// describe. Delete/unload guards use this instead of `loadedTier`, which is nil during a
    /// cold load even though the engine is actively reading those files.
    var isWorking: Bool { busy || describing }

    /// Mark a VLM Describe as in-flight so freeMemory()/delete-guards treat it as busy.
    /// Returns `false` when setting `true` while the engine is already `busy` — generating, OR
    /// unloading inside freeMemory() (which holds `busy` across tearDown's suspension points).
    /// The caller MUST abort the describe then: the actor is reentrant at those await points, so
    /// a Describe launched mid-unload would load the VLM into the process-global MLX pool that
    /// clearAll() is gutting → crash / garbage. This closes the unload→Describe "third door" the
    /// UI gate can't see (a freeMemory()/Clear-cache from ANY tab sets no VM flag the button reads).
    @discardableResult
    func setDescribing(_ value: Bool) -> Bool {
        if value {
            guard !busy else { return false }
            describing = true
            return true
        }
        describing = false
        return true
    }

    // MARK: Loading / tier switching

    /// Ensure a pipeline matching `tier` + `quant` is loaded; reuse if already matching,
    /// otherwise unload the previous model first (memory budget allows only one).
    // N-1: private — must only be called from generate() which already holds the actor
    private func ensureLoaded(
        tier: ModelTier,
        quant: Flux2QuantizationConfig,
        hfToken: String?,
        onDownload: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws {
        if pipeline != nil, loadedTier == tier, sameQuant(loadedQuant, quant) {
            return
        }
        // Different tier/quant (or nothing loaded) → tear the old one down FIRST.
        // Must use tearDown() (no busy-guard), NOT freeMemory() — generate() holds `busy`,
        // and freeMemory() would no-op, skipping clearAll() and leaking the old model.
        if pipeline != nil {
            AppLog.info("Tier switch: \(loadedTier?.shortName ?? "?") → \(tier.shortName) — unloading previous model")
            await tearDown()
        }

        let p = Flux2Pipeline(
            model: tier.flux2Model,
            quantization: quant,
            memoryOptimization: MemoryOptimizationConfig.recommended(forRAMGB: ModelRegistry.systemRAMGB),
            hfToken: hfToken
        )
        try await p.loadModels(progressCallback: onDownload)
        pipeline = p
        loadedTier = tier
        loadedQuant = quant
        appliedLoRAs = []
    }

    // MARK: Generation

    func generate(
        _ req: GenerationRequest,
        hfToken: String?,
        referenceImages: [CGImage] = [],   // empty → T2I; 1–3 → I2I (passed separately to keep GenerationRequest Sendable)
        onDownload: @escaping @Sendable (Double, String) -> Void = { _, _ in },
        onStep: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
        previewEachStep: Bool = false,   // live preview: VAE-decode + onCheckpoint at a checkpoint interval
        previewEveryStep: Bool = false,  // when previewEachStep: decode EVERY step (interval 1) vs once at ~75%
        onCheckpoint: @escaping @Sendable (Int, CGImage) -> Void = { _, _ in }
    ) async throws -> CGImage {
        // Block while a VLM Describe holds the process-global MLX pool too — the Queue "Run all"
        // path isn't UI-gated against describe, and running a denoise/VAE-decode (or a tier-switch
        // tearDown→clearCache) on the pool the VLM is using corrupts buffers / SIGABRTs.
        guard !busy, !describing else { throw FluxEngineError.busy }
        busy = true
        defer { busy = false }

        // Hard safety override. The engine's "Klein I2I with upsampling" branch loads the
        // Mistral-Small 24 GB VLM, which swap-freezes a 32 GB Mac (and re-downloads 24 GB
        // first). Killed HERE (not only in the UI) so no future UI change can reopen the
        // freeze. (The other Mistral door, interpretImagePaths, is gone from
        // GenerationRequest entirely — we always pass nil literals below.)
        var req = req
        if !referenceImages.isEmpty { req.upsamplePrompt = false }

        // Hard memory floor (belt-and-braces — the VM clamps too): on <16 GB the GPU aborts
        // (mlx::core::gpu::check_error throw → SIGABRT) above ~0.8 MP. Clamp so NO path
        // (queue, inline-edited task, restored recipe) can OOM-crash the app.
        let maxArea = ModelRegistry.systemRAMGB < 16 ? 820_000 : 2_359_296
        if req.width > 0, req.height > 0, req.width * req.height > maxArea {
            let s = (Double(maxArea) / Double(req.width * req.height)).squareRoot()
            let cw = max(512, min(1536, Int((Double(req.width) * s / 32).rounded(.down)) * 32))
            let ch = max(512, min(1536, Int((Double(req.height) * s / 32).rounded(.down)) * 32))
            AppLog.info("Size capped for \(ModelRegistry.systemRAMGB) GB RAM: \(req.width)×\(req.height) → \(cw)×\(ch)")
            req.width = cw
            req.height = ch
        }

        // Keep generation sizes on a clean /32 grid (harmless belt-and-braces; the aspect chips
        // already do this). NOTE: this is NOT what fixes the 720/736 horizontal tear — that tear
        // is a DISPLAY artifact (the engine emits a 24-bit no-alpha CGImage that the GPU display
        // layer uploads with a misaligned row stride at some widths; the saved file is actually
        // fine — mlx-swift asArray returns tight logical data). The real fix is displayNormalized()
        // below, which re-renders to standard 32-bit RGBA before the image leaves the engine.
        if req.width > 0, req.height > 0 {
            let sw = max(512, (req.width / 32) * 32)
            let sh = max(512, (req.height / 32) * 32)
            if sw != req.width || sh != req.height {
                AppLog.info("Size snapped to /32: \(req.width)×\(req.height) → \(sw)×\(sh)")
                req.width = sw
                req.height = sh
            }
        }

        // The engine FUSES LoRAs into the transformer weights and cannot unfuse them
        // (LoRAManager.clearWeightsAfterFusion: "cannot be unfused without reloading the base
        // model"); unloadAllLoRAs() only clears bookkeeping. So when the resident weights carry
        // a different LoRA SET (file, scale, or count) than requested, reload clean weights
        // from disk first — otherwise old LoRAs stay baked in (off/removed), stack with new
        // ones (switch), or merge twice (scale change). Compared as Sets: deltas SUM, so
        // slot order doesn't matter and a reorder must not cost a ~50 s reload.
        // Belt-and-braces dedupe by file: fusing the same adapter twice doubles its effect.
        var seenPaths = Set<String>()
        let wantLoRAs = req.loras.filter { seenPaths.insert($0.path).inserted }
        let wantFused = wantLoRAs.map { FusedLoRA(use: $0, stamp: Self.fileStamp($0.path)) }
        let loraChanged = Set(wantFused) != Set(appliedLoRAs)
        if loraChanged, !appliedLoRAs.isEmpty, pipeline != nil {
            AppLog.info("LoRA selection changed — reloading clean model weights")
            await tearDown()
        }

        try await ensureLoaded(tier: req.tier, quant: req.quant, hfToken: hfToken, onDownload: onDownload)
        guard let pipeline else { throw FluxEngineError.notLoaded }

        // Fuse the requested set when it isn't already in the weights. (After the teardown
        // above appliedLoRAs is empty again, so this also performs the post-reload merge.
        // Sequential loadLoRA is safe: each merge applies only its own deltas — net A+B.)
        if Set(wantFused) != Set(appliedLoRAs) {
            pipeline.unloadAllLoRAs()
            appliedLoRAs = []
            for lora in wantFused {
                _ = try pipeline.loadLoRA(LoRAConfig(filePath: lora.use.path, scale: lora.use.scale))
                // Recorded ONE BY ONE so a throw on the NEXT adapter leaves the bookkeeping
                // truthful (non-empty partial set) — the teardown gate above then reloads
                // clean weights on the next request instead of doubling the baked adapter.
                appliedLoRAs.append(lora)
                AppLog.info("LoRA fused: \(lora.use.name) @ \(String(format: "%.2f", lora.use.scale))")
            }
        }

        // Live preview: the engine VAE-decodes the latents every `checkpointInterval` steps
        // and hands a CGImage to onCheckpoint. Early Klein steps are pure noise mush, so by
        // default interval = steps-1 = ONE preview at the second-to-last step (75% for 4 steps),
        // the first moment it reads as an image, for a single extra VAE decode. previewEveryStep
        // sets interval = 1 (Draw-Things style: a frame after EVERY step, incl. the noisy early
        // ones, at the cost of one extra VAE decode per step).
        let checkpointInterval: Int? = previewEachStep ? (previewEveryStep ? 1 : max(1, req.steps - 1)) : nil
        // Normalise the preview frame to 32-bit RGBA too, so live preview doesn't tear on screen.
        let checkpointCallback: (@Sendable (Int, CGImage) -> Void)? = previewEachStep
            ? { @Sendable step, img in onCheckpoint(step, Self.displayNormalized(img)) }
            : nil

        let result: CGImage
        if !referenceImages.isEmpty {
            result = try await pipeline.generateImageToImage(
                prompt: req.prompt,
                images: referenceImages,
                interpretImagePaths: nil,
                height: req.height,
                width: req.width,
                steps: req.steps,
                guidance: req.guidance,
                seed: req.seed,
                upsamplePrompt: req.upsamplePrompt,
                checkpointInterval: checkpointInterval,
                onProgress: onStep,
                onCheckpoint: checkpointCallback
            )
        } else {
            result = try await pipeline.generateTextToImage(
                prompt: req.prompt,
                interpretImagePaths: nil,
                height: req.height,
                width: req.width,
                steps: req.steps,
                guidance: req.guidance,
                seed: req.seed,
                upsamplePrompt: req.upsamplePrompt,
                checkpointInterval: checkpointInterval,
                onProgress: onStep,
                onCheckpoint: checkpointCallback
            )
        }
        return Self.displayNormalized(result)
    }

    /// Re-render the engine's CGImage into the standard 32-bit premultiplied RGBA format.
    /// The pipeline returns a 24-bit (bitsPerPixel 24, alpha none, row stride = width×3) image —
    /// an unusual format that the GPU display layer uploads with a misaligned row stride at some
    /// widths (e.g. 720, 736), painting horizontal tear bands ON SCREEN. The underlying pixels are
    /// correct (mlx-swift asArray copies tight logical data; the saved PNG is fine), so this is a
    /// pure display-format fix: 32-bit RGBA is what CoreAnimation/Metal handle natively at ANY
    /// width. Normalising once here makes the canvas, gallery thumbnails, save and drag-out all
    /// robust regardless of size. Returns the original on the (unexpected) failure path.
    nonisolated static func displayNormalized(_ img: CGImage) -> CGImage {
        let w = img.width, h = img.height
        guard w > 0, h > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    // MARK: Memory

    /// Public "free memory" action. No-op (returns false) while a generation OR a VLM describe
    /// is in flight — you can't tear down a pipeline / clear the global MLX pool from under
    /// either. Returns true if it actually unloaded.
    @discardableResult
    func freeMemory() async -> Bool {
        guard !busy, !describing else { return false }
        // 🔴 Hold `busy` across tearDown's suspension points (clearAll awaits unloadTextEncoder).
        // Without it the actor is reentrant here: a generate() entering mid-teardown would see
        // busy==false, pass its guard, and ensureLoaded would early-return on the still-non-nil
        // pipeline that clearAll is gutting → crash / garbage render. With the flag, that
        // concurrent generate() throws .busy instead.
        busy = true
        defer { busy = false }
        await tearDown()
        return true
    }

    /// Actually unload the resident model + clear MLX caches. Private + NO busy-guard, so it
    /// can run during a tier switch inside generate() (which holds `busy`).
    private func tearDown() async {
        await pipeline?.clearAll()
        pipeline = nil
        loadedTier = nil
        loadedQuant = nil
        appliedLoRAs = []
        Memory.clearCache()
    }

    // MARK: Helpers

    private func sameQuant(_ a: Flux2QuantizationConfig?, _ b: Flux2QuantizationConfig) -> Bool {
        guard let a else { return false }
        return a.transformer == b.transformer && a.textEncoder == b.textEncoder
    }
}
