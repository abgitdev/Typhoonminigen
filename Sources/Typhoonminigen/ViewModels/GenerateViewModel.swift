import SwiftUI
import Observation
import CoreGraphics
import Flux2Core

/// Drives one text-to-image generation: inputs, live progress + ETA, result.
@MainActor
@Observable
final class GenerateViewModel {
    // MARK: Inputs
    // The draft form (size / toggles / batch) persists across launches — losing dialed-in
    // settings to an accidental quit costs real work. The PROMPT deliberately does NOT
    // persist (privacy, 2026-06-11): it's user content, and settings were the only place it
    // lived outside the gallery. Seed is also not persisted: a stale fixed seed silently
    // stamps every new series (user-reported confusion).
    var prompt: String = ""
    /// Selected model tier. Persisted across launches; first launch defaults by RAM
    /// (see init). Switching clears the LoRA selection — a dim-4096 adapter fused into the
    /// 4B transformer (or vice versa) is silent weight corruption: the engine only LOGS a
    /// mismatch warning and merges anyway.
    var tier: ModelTier = .klein9B {
        didSet {
            guard tier != oldValue else { return }
            UserDefaults.standard.set(tier.rawValue, forKey: Self.tierKey)
            for i in loraSlots.indices { loraSlots[i].item = nil }
            reloadLoRAs()
            Task { @MainActor in await syncModelState() }  // pill: is THIS tier resident?
            AppLog.info("Model tier switched to \(tier.shortName)")
        }
    }
    // Size persists only while it's the USER'S size: adding a reference auto-snaps the
    // dims (preReferenceSize holds the original), and persisting that snap would restore
    // a reference-derived size on relaunch with no reference in sight to explain it.
    var width: Int = 1024 {
        didSet {
            guard preReferenceSize == nil else { return }
            UserDefaults.standard.set(width, forKey: Self.draftWidthKey)
        }
    }
    var height: Int = 1024 {
        didSet {
            guard preReferenceSize == nil else { return }
            UserDefaults.standard.set(height, forKey: Self.draftHeightKey)
        }
    }
    var seedText: String = ""          // empty = random

    /// Klein step/guidance defaults come from the tier (4 steps / 1.0).
    var steps: Int { tier.defaultSteps }
    var guidance: Float { tier.defaultGuidance }

    // MARK: State
    var isBusy = false
    var statusMessage = ""
    var progress: Double = 0           // 0...1
    var etaSeconds: Double? = nil
    var currentStep: Int = 0           // last completed denoise step (for the rail)
    var resultImage: CGImage? = nil
    var errorMessage: String? = nil
    var lastSavedURL: URL? = nil
    var savedImageCount = 0            // bumped once per gallery save — a MONOTONIC signal the
                                       // Gallery observes; lastSavedURL toggles nil→URL→nil within
                                       // one queue run so it never reaches SwiftUI as a change (#live-refresh)
    var isModelLoaded = false          // SELECTED tier resident in RAM (drives the status pill)
    var residentTier: ModelTier? = nil // whichever tier the engine actually holds (unload button)
    // Stored (not computed) so the idle canvas doesn't re-stat the disk on every telemetry
    // tick — refreshed by syncModelState (tab switch, tier change, downloads, gen end).
    var modelMissing = false           // selected tier's transformer not on disk → canvas CTA
    var encoderMissing = false         // selected tier's Qwen3 encoder not on disk → CTA variant
    var lastGenSeconds: Double? = nil  // wall-clock of the last completed generation
    var lastSeed: UInt64? = nil        // seed of the last completed generation (for the canvas overlay)

    // LoRA selection (only adapters compatible with the current tier are offered).
    // Two slots — the engine fuses adapters sequentially and their deltas SUM, so a
    // style + a subject LoRA can be combined; each slot has its own strength.
    struct LoRASlot: Identifiable {
        let id: Int
        var item: LoRAItem? = nil
        var scale: Float = 1.0
    }
    var availableLoRAs: [LoRAItem] = []
    /// Every compatible adapter on disk, unfiltered by tier — drives the "switch to the
    /// other tier to use these" hint when the current tier has no matching adapters.
    private var allLoRAsOnDisk: [LoRAItem] = []
    /// Adapters on disk built for the OTHER tier (empty unless the active tier has none of its own).
    var loRAsForOtherTier: [LoRAItem] { allLoRAsOnDisk.filter { $0.tier != nil && $0.tier != tier } }
    var loraSlots: [LoRASlot] = [LoRASlot(id: 0), LoRASlot(id: 1)]
    /// The slots that actually carry a selection (drives the UI notes and the request).
    var activeLoRASlots: [LoRASlot] { loraSlots.filter { $0.item != nil } }
    var upsamplePrompt = false {
        didSet { UserDefaults.standard.set(upsamplePrompt, forKey: Self.upsampleKey) }
    }

    /// Clear one LoRA slot, then keep the slots compact. The slot-1 UI is gated on slot 0,
    /// so an orphaned slot 1 would be INVISIBLY active (still fused, trigger still appended).
    func clearLoRASlot(_ index: Int) {
        loraSlots[index].item = nil
        compactLoRASlots()
    }

    /// Slot 1 never survives without slot 0 — promote it (selection + scale) instead.
    private func compactLoRASlots() {
        if loraSlots[0].item == nil, loraSlots[1].item != nil {
            loraSlots[0].item = loraSlots[1].item
            loraSlots[0].scale = loraSlots[1].scale
            loraSlots[1].item = nil
            loraSlots[1].scale = 1.0
        }
    }

    // Prompt presets — camera / shot / lighting / style chips appended to the prompt at generation.
    var selectedPresetIDs: Set<String> = []

    // I2I — reference images (empty = T2I mode). The engine accepts at most 3.
    struct ReferenceSlot: Identifiable {
        let id = UUID()
        let image: CGImage
        let url: URL?   // nil when fed from the canvas result before it was saved
    }
    var references: [ReferenceSlot] = []
    static let maxReferences = 3
    var isDescribing = false   // Qwen3.5-VLM is reading the references right now
    var isUpscaling = false    // Real-ESRGAN is enlarging the last result

    // Generation queue — "Generate" enqueues `batchCount` items (series of seeds) and renders
    // now; "Add to queue" composes tasks without running. Items run strictly one at a time (the
    // engine actor serializes anyway). request/label are var so a pending task can be edited (#2).
    struct QueueItem: Identifiable {
        let id = UUID()
        var request: GenerationRequest
        let referenceImages: [CGImage]
        var label: String        // short prompt excerpt for the queue list
    }
    var queue: [QueueItem] = []
    var queueRunning = false
    var queueDone = 0            // finished items in the current run
    var queueTotal = 0           // total enqueued in the current run
    var batchCount = 1 {         // how many seeds "Generate" enqueues at once
        didSet { UserDefaults.standard.set(batchCount, forKey: Self.batchKey) }
    }
    var currentItemID: QueueItem.ID? = nil
    var lastSavedGenID: UUID? = nil          // gallery id of the on-canvas render (#11 "delete it")
    var lastResultWasCancelled = false       // the kept frame came from a stopped run

    /// Seed strategy when duplicating a queued task (#1 scheduler).
    enum SeedMode: Sendable { case newRandom, same, sequential }

    // Live render preview — the engine VAE-decodes the latents after every step and the
    // canvas shows the image taking shape. Costs ~one VAE decode per step (a few seconds
    // per image at 1024²), so it's a toggle.
    var livePreview = false {
        didSet { UserDefaults.standard.set(livePreview, forKey: Self.livePreviewKey) }
    }
    var previewImage: CGImage? = nil
    var previewStep: Int = 0
    var previewEveryStep = false {   // when livePreview is on: show EVERY step like Draw Things (noisy early frames) vs one clean frame at ~75%
        didSet { UserDefaults.standard.set(previewEveryStep, forKey: Self.previewEveryStepKey) }
    }

    // MARK: Internals
    private let engine: FluxEngine
    private let store: GenerationStore
    private let loraStore: LoRAStore
    private let sessionStats: SessionStats
    private var genTask: Task<Void, Never>? = nil
    private var describeTask: Task<Void, Never>? = nil
    private var genStart: Date? = nil
    private var cancelledGen = false
    // Bumped at the start of every queue item. Late MainActor hops (a preview checkpoint
    // landing after cancel) and the sleeping idle-unload task check it so a stale callback
    // can't re-pin an old preview or unload right under a fresh run.
    private var generationEpoch = 0
    private var preReferenceSize: (width: Int, height: Int)? = nil  // dims to restore on Remove
    private var idleUnloadTask: Task<Void, Never>? = nil   // frees ~9–19 GB when the user walks away
    private static let idleUnloadMinutes = 15

    init(engine: FluxEngine, store: GenerationStore, loraStore: LoRAStore, sessionStats: SessionStats) {
        self.engine = engine
        self.store = store
        self.loraStore = loraStore
        self.sessionStats = sessionStats
        // Restore the preset selection from the last launch, dropping ids that no longer exist
        // (e.g. a deleted custom chip) AND ids hidden via the context menu — a hidden built-in
        // used to come back ALREADY selected, silently re-entering the prompt.
        let saved = UserDefaults.standard.array(forKey: Self.presetSelectionKey) as? [String] ?? []
        selectedPresetIDs = Set(saved.filter { PresetCatalog.category(for: $0) != nil })
            .subtracting(CustomPresetStore.shared.hiddenIDs)
        // Tier: stored preference wins; on first launch auto-detect by RAM. 9B peaks at
        // ~19–20 GB phys_footprint (measured on the 32 GB M4) + ~4–5 GB macOS, so 24 GB
        // machines land at the edge — only ≥32 GB defaults to 9B (user decision 2026-06-10).
        if let raw = UserDefaults.standard.string(forKey: Self.tierKey),
           let storedTier = ModelTier(rawValue: raw) {
            tier = storedTier
        } else if ramGB < 32 {
            tier = .klein4B
        }
        // Seed a neutral sample prompt whenever the box would otherwise be empty on launch —
        // so first use AND a fresh start after "Remove all data" aren't an intimidating blank
        // field. The prompt is session-only (never persisted — privacy), so this re-seeds on
        // each launch until the user types their own; it never overwrites typed text mid-session.
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = "A serene mountain lake at sunrise, soft mist over the water, pine forest, warm golden light"
        }
        // Restore the draft form (prompt intentionally absent — see its declaration).
        // The didSet observers fire on these assignments and write the same values back —
        // harmless. Width/height are validated so a corrupted default can't smuggle in an
        // unsafe generation size.
        UserDefaults.standard.removeObject(forKey: "draftPrompt")  // scrub drafts saved by pre-0.45 builds
        let w = UserDefaults.standard.integer(forKey: Self.draftWidthKey)
        let h = UserDefaults.standard.integer(forKey: Self.draftHeightKey)
        // Snap restored drafts to /32 — a pre-fix build may have persisted a tearing width (720).
        if (ReferenceSize.minSide...ReferenceSize.maxSide).contains(w) { width = ReferenceSize.snap(w) }
        if (ReferenceSize.minSide...ReferenceSize.maxSide).contains(h) { height = ReferenceSize.snap(h) }
        // Live preview now defaults to Off. Apply that new default ONCE to existing installs
        // too (the user asked for Off by default); afterwards their own choice persists normally.
        if UserDefaults.standard.bool(forKey: Self.previewDefaultOffKey) {
            if UserDefaults.standard.object(forKey: Self.livePreviewKey) != nil {
                livePreview = UserDefaults.standard.bool(forKey: Self.livePreviewKey)
            }
            previewEveryStep = UserDefaults.standard.bool(forKey: Self.previewEveryStepKey)
        } else {
            // didSet does NOT fire for assignments inside init, so persist explicitly —
            // otherwise the stale stored value reloads on the next launch and the new
            // Off-default is lost after one run.
            UserDefaults.standard.set(true, forKey: Self.previewDefaultOffKey)
            UserDefaults.standard.set(false, forKey: Self.livePreviewKey)
            UserDefaults.standard.set(false, forKey: Self.previewEveryStepKey)
            livePreview = false
            previewEveryStep = false
        }
        upsamplePrompt = UserDefaults.standard.bool(forKey: Self.upsampleKey)
        let batch = UserDefaults.standard.integer(forKey: Self.batchKey)
        if (1...8).contains(batch) { batchCount = batch }
    }

    private static let presetSelectionKey = "selectedPresetIDs"
    private static let tierKey = "selectedModelTier"
    private static let previewEveryStepKey = "previewEveryStep"
    private static let draftWidthKey = "draftWidth"
    private static let draftHeightKey = "draftHeight"
    private static let didSeedPromptKey = "didSeedPrompt"   // one-time first-launch sample prompt
    private static let livePreviewKey = "livePreview"
    private static let previewDefaultOffKey = "previewDefaultOffApplied"   // one-time migration to Off-by-default
    private static let upsampleKey = "upsamplePrompt"
    private static let batchKey = "batchCount"

    /// Physical RAM in GB (drives the tier default and the 9B-on-small-Mac warning).
    var ramGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    /// Output area past which Klein quality degrades (mutations) — its sweet spot is
    /// ~1.05 MP regardless of tier; the engine has no working size guard of its own.
    /// 1_100_000 so 1152×1024 (1.18 MP) already warns, 1024×1024 doesn't.
    var sizeIsLarge: Bool { width * height > 1_100_000 }

    /// Max generation AREA (px) this Mac can VAE-decode without the GPU aborting. <16 GB
    /// (i.e. 8 GB) crashes above ~0.8 MP — 896²=0.80 MP works, 1024²=1.05 MP aborts (GPU
    /// command-buffer OOM → mlx check_error throw → abort). 16/32 GB take the full range.
    var maxGenArea: Int { ramGB < 16 ? 820_000 : 2_359_296 }

    /// Clamp a size to `maxGenArea`, preserving aspect + /32 (stride-safe) granularity. No-op if it fits.
    func clampedSizeForRAM(_ w: Int, _ h: Int) -> (width: Int, height: Int) {
        guard w > 0, h > 0, w * h > maxGenArea else { return (w, h) }
        let s = (Double(maxGenArea) / Double(w * h)).squareRoot()
        // floor (not round) so the result is ALWAYS ≤ maxGenArea (rounding could push it back over
        // the cap), AND /32 so the capped width's RGB row stride stays 32-aligned (else it tears).
        // 1024² on 8 GB → 896² (803k ≤ 820k, /32-safe).
        let cw = max(ReferenceSize.minSide, min(ReferenceSize.maxSide, Int((Double(w) * s / 32).rounded(.down)) * 32))
        let ch = max(ReferenceSize.minSide, min(ReferenceSize.maxSide, Int((Double(h) * s / 32).rounded(.down)) * 32))
        return (cw, ch)
    }

    // NOTE: no isBusy gate — while the queue runs the same button ADDS to the queue
    // (the leftover isBusy check from the pre-queue era silently swallowed every
    // "Add to queue" click — user-reported twice).
    var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isDescribing   // VLM holds ~3 GB + GPU — finish describing before generating
        && !seedIsInvalid  // S-6: disable button instead of showing an error after tap
    }

    /// Seed text with separators stripped — pasted seeds often carry locale commas/spaces
    /// (the gallery used to display them that way).
    private var cleanedSeedText: String {
        seedText.filter { $0.isNumber }
    }

    var seedValue: UInt64? {
        let t = cleanedSeedText
        return t.isEmpty ? nil : UInt64(t)
    }

    /// True if the seed field has text that isn't a valid number.
    var seedIsInvalid: Bool {
        let raw = seedText.trimmingCharacters(in: .whitespaces)
        return !raw.isEmpty && UInt64(cleanedSeedText) == nil
    }

    /// Human-friendly time of the last generation, e.g. "47 s" or "2 min 27 s".
    var lastGenText: String? {
        guard let s = lastGenSeconds else { return nil }
        if s < 60 { return String(format: "%.0f s", s) }
        return "\(Int(s) / 60) min \(Int(s) % 60) s"
    }

    // MARK: Actions

    /// Generate-screen primary: enqueue `batchCount` items (one per seed) and start the run if
    /// the queue is idle. With a fixed seed the series uses seed, seed+1, … (reproducible).
    func generate() {
        guard canGenerate, ensureModelReady() else { return }
        idleUnloadTask?.cancel()
        errorMessage = nil
        enqueueFromForm()
        if queueRunning {
            statusMessage = "Added to queue — \(max(0, queue.count - 1)) waiting"
            AppLog.info("Added \(max(1, batchCount)) item(s) to queue (\(max(0, queue.count - 1)) waiting)")
        } else {
            startQueue()
        }
    }

    /// "Add to queue": compose a task (or batch) from the current form WITHOUT starting the run
    /// — build a list of different prompts, then "Run all" on the Queue tab. (#1)
    func addTaskToQueue() {
        guard canGenerate else { return }
        idleUnloadTask?.cancel()
        errorMessage = nil
        enqueueFromForm()
        let n = queue.count
        statusMessage = "Added to queue — \(n) task\(n == 1 ? "" : "s") waiting"
        AppLog.info("Added \(max(1, batchCount)) task(s) to the queue (now \(n))")
    }

    /// Library quick-add (#queue-presets): append ONE task built from a scene recipe — its subject +
    /// chips, combined with the CURRENT technical settings (tier, size, LoRA). Doesn't touch the form
    /// or the canvas and works while a render runs, so you can line up several scenes and walk away.
    /// Each add gets its OWN random seed (a varied batch must not share one — pin a specific seed
    /// later via the Queue editor). Returns the new queue length.
    @discardableResult
    func enqueueScene(_ recipe: SceneRecipe) -> Int {
        errorMessage = nil   // a stale render error would otherwise hide the "Added — N in queue" confirmation in the Library
        idleUnloadTask?.cancel()
        // The scene's chips apply via buildRequest's ignoringHidden suffix — no need to permanently
        // un-hide them globally (a queue-add must not mutate the user's hidden-chip set).
        // Each Library add gets its OWN random seed: queuing a batch of DIFFERENT scenes must not
        // stamp them all with the form's pinned seed (a fixed seed is for reproducing ONE
        // composition, not a varied batch). Pin a specific seed by editing the task in the Queue.
        let seed = UInt64.random(in: 0 ... UInt64.max)
        let req = buildRequest(seed: seed,
                               promptOverride: recipe.subjectExample,
                               presetIDsOverride: Set(recipe.chipIDs))
        // A scene is text-to-image — don't inherit the form's leftover references (that silently
        // turned it into an I2I run). buildRequest already empties refPaths for an override.
        queue.append(QueueItem(request: req, referenceImages: [], label: queueLabel(req)))
        if queueRunning { queueTotal += 1 }
        AppLog.info("Scene added to queue: \(recipe.id) (now \(queue.count))")
        return queue.count
    }

    /// #2 Inline-edit a PENDING queued task (prompt / size / seed). Size is clamped to Klein's
    /// 512–1536 range and snapped to /32 (stride-safe); a nil seed renders random. The task that
    /// is currently rendering can't be edited.
    func updateTask(_ id: UUID, prompt: String, width: Int, height: Int, seed: UInt64?) {
        guard id != currentItemID, let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].request.prompt = prompt
        // Snap to /32 AND clamp to the RAM-safe area, so an edited task can't store a recipe whose
        // recorded size disagrees with the pixels actually rendered (the engine re-clamps its copy).
        let c = clampedSizeForRAM(ReferenceSize.snap(width), ReferenceSize.snap(height))
        queue[idx].request.width = c.width
        queue[idx].request.height = c.height
        queue[idx].request.seed = seed
        queue[idx].label = queueLabel(queue[idx].request)
        // Surface a silent size adjustment (out-of-range / RAM cap / /32 snap) instead of just
        // saving a different size than the user typed.
        if c.width != width || c.height != height {
            statusMessage = "Task \(idx + 1) updated — size adjusted to \(c.width)×\(c.height)."
        } else {
            statusMessage = "Task \(idx + 1) updated"
        }
    }

    /// Queue-tab "Run all": start the composed queue. (#1)
    func runAll() {
        guard !isDescribing else {
            errorMessage = "Finish describing the reference first — it's using the GPU."
            return
        }
        guard !queueRunning, !queue.isEmpty, ensureModelReady() else { return }
        idleUnloadTask?.cancel()
        errorMessage = nil
        startQueue()
    }

    /// The selected model + encoder must be on disk before a run — otherwise the engine fetches
    /// gigabytes silently mid-generation. (Queued mixed-tier items are re-checked per item.)
    private func ensureModelReady() -> Bool {
        if !Flux2ModelDownloader.isDownloaded(.transformer(tier.transformerVariant)) {
            errorMessage = "\(tier.shortName) isn't downloaded yet. Open the Models tab to download it, then come back."
            statusMessage = ""
            return false
        }
        if !tier.isEncoderDownloaded {
            errorMessage = "The \(tier.shortName) text encoder isn't downloaded — open the Models tab and press \u{201C}Get encoder\u{201D}."
            statusMessage = ""
            return false
        }
        return true
    }

    /// Append `batchCount` tasks built from the CURRENT form (does not start the run).
    private func enqueueFromForm() {
        let baseSeed = seedValue
        let refImages = references.map(\.image)   // snapshot — items keep their own references
        for i in 0 ..< max(1, batchCount) {
            let seed = baseSeed.map { $0 &+ UInt64(i) } ?? UInt64.random(in: 0 ... UInt64.max)
            let req = buildRequest(seed: seed)
            queue.append(QueueItem(request: req, referenceImages: refImages, label: queueLabel(req)))
        }
        if queueRunning { queueTotal += max(1, batchCount) }   // keep "Image N of M" honest for mid-run adds
    }

    /// Assemble the effective request from the CURRENT form state (prompt + LoRA trigger +
    /// preset phrases + size + references' paths).
    /// `promptOverride`/`presetIDsOverride` let the Library queue a SCENE (its own subject + chips)
    /// without disturbing the form; nil = use the live form (the normal Generate / Add-to-queue path).
    private func buildRequest(seed: UInt64, promptOverride: String? = nil, presetIDsOverride: Set<String>? = nil) -> GenerationRequest {
        // Belt-and-braces: never let a wrong-tier adapter into a request. The tier didSet
        // clears the selections, but if any window ever lets one slip through, the engine
        // would FUSE it with only a log warning (dim 3072 vs 4096 = corrupted weights).
        // Also dedupe by file — fusing the same adapter twice doubles its effect.
        var seenFiles = Set<String>()
        let activeLoRAs: [(item: LoRAItem, scale: Float)] = loraSlots.compactMap { slot in
            guard let item = slot.item, item.tier == tier,
                  seenFiles.insert(item.url.path).inserted else { return nil }   // same key as the engine's dedupe
            return (item, slot.scale)
        }
        // Auto-append each selected LoRA's trigger word so it's never forgotten.
        var effectivePrompt = promptOverride ?? prompt
        for (item, _) in activeLoRAs where !item.trigger.isEmpty {
            // Word-boundary match, not substring: a trigger "art" must still be added to a
            // prompt that only contains "smart" (the UI promised the trigger would be added).
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: item.trigger) + "\\b"
            if effectivePrompt.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil {
                effectivePrompt += (effectivePrompt.isEmpty ? "" : ", ") + item.trigger
            }
        }
        // A Library scene (override args set) is its OWN composition — it must not inherit the
        // form's leftover references or write back to the form/status.
        let isOverride = promptOverride != nil || presetIDsOverride != nil
        // Append selected preset phrases (camera/technical last so the subject stays front-loaded).
        // A scene queued from the Library passes its OWN chip ids here instead of the form's,
        // ignoringHidden so a chip the user hid still applies WITHOUT globally un-hiding it.
        let suffix = presetIDsOverride.map { PresetCatalog.suffix(for: $0, ignoringHidden: true) } ?? presetSuffix
        if !suffix.isEmpty {
            effectivePrompt += (effectivePrompt.isEmpty ? "" : ", ") + suffix
        }
        // A scene is text-to-image — never bake the form's reference PATHS into it (that turned a
        // T2I scene into a silent I2I run). Only the live form contributes references.
        let refPaths = isOverride ? [] : references.compactMap { $0.url?.path }
        // 8 GB safety: clamp to a size the GPU can actually decode (≥1 MP aborts on 8 GB).
        // Done HERE so the request AND the saved recipe carry the real size, and the form
        // updates to show what actually ran.
        let capped = clampedSizeForRAM(width, height)
        // Only the live-form Generate path may write back to the form/status. A Library scene
        // stays side-effect-free — it bakes the capped size into the request only.
        if !isOverride, capped.width != width || capped.height != height {
            statusMessage = "Size capped to \(capped.width)×\(capped.height) — \(ramGB) GB runs out of GPU memory above ~0.8 MP."
            width = capped.width
            height = capped.height
        }
        return GenerationRequest(
            prompt: effectivePrompt,
            tier: tier,
            quant: tier.recommendedQuant,
            width: capped.width,
            height: capped.height,
            steps: steps,
            guidance: guidance,
            seed: seed,
            loras: activeLoRAs.map { LoRAUse(path: $0.item.url.path, name: $0.item.fileName, scale: $0.scale) },
            // With references the engine's upsampling would load a 24 GB Mistral VLM
            // (swap-freeze on 32 GB) — force it off in I2I. FluxEngine enforces this too.
            upsamplePrompt: upsamplePrompt && references.isEmpty,
            referenceImagePaths: refPaths.isEmpty ? nil : refPaths
        )
    }

    private func queueLabel(_ req: GenerationRequest) -> String {
        let words = req.prompt.split(separator: " ").prefix(5).joined(separator: " ")
        return words.isEmpty ? "(empty prompt)" : words
    }

    /// Remove a PENDING task (the running one can only be stopped).
    func removeQueued(_ id: QueueItem.ID) {
        let before = queue.count
        queue.removeAll { $0.id == id && $0.id != currentItemID }
        if queue.count < before, queueRunning { queueTotal -= 1 }   // keep "Image N of M" honest
    }

    /// Duplicate a task `count` times with the chosen seed strategy (#1). Copies land right
    /// after the source, so "same prompt × many seeds" reads in order.
    func duplicateTask(_ id: QueueItem.ID, count: Int, seedMode: SeedMode) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let src = queue[idx]
        // A source with no pinned seed renders a fresh random seed; "same"/"sequential" copies
        // would otherwise all get 0 (matching neither the source nor the intent). Resolve one
        // concrete seed, and pin the source too (unless it's mid-render) so the copies relate to it.
        let baseSeed = src.request.seed ?? UInt64.random(in: 0 ... UInt64.max)
        if src.request.seed == nil, seedMode != .newRandom, src.id != currentItemID {
            queue[idx].request.seed = baseSeed
        }
        var copies: [QueueItem] = []
        for i in 0 ..< max(1, count) {
            var req = src.request
            switch seedMode {
            case .same:       req.seed = baseSeed
            case .sequential: req.seed = baseSeed &+ UInt64(i + 1)
            case .newRandom:  req.seed = UInt64.random(in: 0 ... UInt64.max)
            }
            copies.append(QueueItem(request: req, referenceImages: src.referenceImages, label: src.label))
        }
        queue.insert(contentsOf: copies, at: idx + 1)
        if queueRunning { queueTotal += copies.count }
    }

    /// Move a PENDING task up/down. The running task (always at the front) can't move.
    func moveTask(_ id: QueueItem.ID, up: Bool) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? idx - 1 : idx + 1
        guard queue.indices.contains(target),
              queue[idx].id != currentItemID, queue[target].id != currentItemID else { return }
        queue.swapAt(idx, target)
    }

    /// Empty the queue of PENDING tasks (a running task keeps going — use Stop for that).
    func clearQueue() {
        queue.removeAll { $0.id != currentItemID }
        if queueRunning { queueTotal = queueDone + queue.count }
    }

    private func startQueue() {
        guard !queueRunning, !queue.isEmpty else { return }
        queueRunning = true
        cancelledGen = false
        queueDone = 0
        queueTotal = queue.count
        genTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = 0, attempted = 0
            var runNotes: [String] = []   // per-item skip/failure reasons — runOne clears errorMessage each item, so capture it here
            while let item = self.queue.first, !Task.isCancelled, !self.cancelledGen {
                self.currentItemID = item.id
                if await self.runOne(item) { succeeded += 1 }
                else if let note = self.errorMessage { runNotes.append(note) }
                attempted += 1
                // Remove the item we just ran BY ID (safe under reorder/duplicate), not by position.
                self.queue.removeAll { $0.id == self.currentItemID }
                self.queueDone += 1
                if self.cancelledGen { break }   // Stop: leave remaining tasks queued for "Run all"
            }
            let stopped = self.cancelledGen
            let wasSeries = self.queueTotal > 1
            self.currentItemID = nil
            self.cancelledGen = false
            self.queueRunning = false
            self.isBusy = false
            self.queueDone = 0
            self.queueTotal = 0
            self.scheduleIdleUnload()

            let failed = attempted - succeeded
            if stopped {
                self.statusMessage = self.queue.isEmpty
                    ? "Stopped."
                    : "Stopped — \(self.queue.count) task(s) kept. Run all to resume."
                AppLog.info("Run stopped: \(succeeded) made, \(self.queue.count) kept")
            } else if wasSeries {
                QueueNotifier.notifyFinished(count: succeeded)
                AppLog.info("Queue finished: \(succeeded) image(s)" + (failed > 0 ? " (\(failed) failed)" : ""))
                // Don't let the last item's success message hide that earlier items were skipped/failed.
                if failed > 0 {
                    self.errorMessage = nil
                    self.statusMessage = "Queue finished: \(succeeded) made, \(failed) skipped/failed."
                        + (runNotes.first.map { " First issue: \($0)" } ?? "")
                }
            } else if succeeded == 1,
                      let secs = self.lastGenSeconds, secs > 60,
                      !NSApplication.shared.isActive {
                // Single renders past a minute (multi-ref I2I runs 6–10 min) — ping the user if
                // they switched away; silent when they're watching the canvas.
                QueueNotifier.notifyFinished(count: 1)
            }
        }
    }

    /// Run ONE queue item through the engine, updating all the live observables.
    /// Returns true only if this item produced an image that was actually saved to the gallery,
    /// so the queue counts/announces REAL finished images (not failed/cancelled attempts).
    @discardableResult
    private func runOne(_ item: QueueItem) async -> Bool {
        // Per-item download guard: a queued mixed-tier task whose model isn't on disk would make
        // the engine fetch gigabytes silently. Skip it instead of triggering a hidden download.
        guard Flux2ModelDownloader.isDownloaded(.transformer(item.request.tier.transformerVariant)),
              item.request.tier.isEncoderDownloaded else {
            errorMessage = "\(item.request.tier.shortName) isn't downloaded — open the Models tab. (Task skipped.)"
            return false
        }
        generationEpoch += 1
        let epoch = generationEpoch
        resultImage = nil
        // Clear the previous render's saved-file URL up front: until THIS item saves, the
        // canvas save/drag/upscale must not act on the prior image (buttons disable on nil).
        lastSavedURL = nil
        previewImage = nil
        previewStep = 0
        progress = 0
        etaSeconds = nil
        currentStep = 0
        lastGenSeconds = nil
        errorMessage = nil   // a prior queue item's error must not hide this item's outcome
        isBusy = true
        cancelledGen = false
        statusMessage = queueTotal > 1 ? "Image \(queueDone + 1) of \(queueTotal)…" : "Preparing…"
        genStart = Date()
        AppLog.info("Generation started: \(item.request.tier.displayName), \(item.request.width)×\(item.request.height)"
                    + (item.referenceImages.isEmpty ? "" : " · \(item.referenceImages.count) ref"))
        let token = HFToken.current(for: item.request.tier)
        let wantPreview = livePreview
        let wantEveryStep = previewEveryStep
        // Pin a concrete seed BEFORE generating. A nil (random) seed makes the engine roll its
        // OWN seed we can't read back — recording the literal 0 then lies on the canvas overlay,
        // the gallery record, the PNG filename and the embedded recipe (irreproducible). Resolve
        // it here and feed the SAME value to the engine and to store.save so they all agree.
        // (enqueueFromForm/enqueueScene already resolve concrete seeds; this covers any remaining
        // nil-seed item — e.g. duplicate "same seed" on a nil-seed source.)
        let seed = item.request.seed ?? UInt64.random(in: 0 ... UInt64.max)
        var request = item.request
        request.seed = seed
        do {
            let image = try await engine.generate(
                request,
                hfToken: token,
                referenceImages: item.referenceImages,
                onDownload: { _, message in
                    Task { @MainActor in self.statusMessage = message }
                },
                onStep: { current, total in
                    Task { @MainActor in
                        // Same epoch/isBusy guard as onCheckpoint — a late progress hop must not
                        // write onto the NEXT item's rail after this one finished or was cancelled.
                        guard self.generationEpoch == epoch, self.isBusy else { return }
                        self.updateProgress(current: current, total: total)
                    }
                },
                previewEachStep: wantPreview,
                previewEveryStep: wantEveryStep,
                onCheckpoint: { step, img in
                    Task { @MainActor in
                        // A checkpoint hop can land after cancel/finish — don't re-pin a
                        // stale ~4-9 MB preview over the cleared state.
                        guard self.generationEpoch == epoch, self.isBusy else { return }
                        self.previewImage = img
                        self.previewStep = step
                    }
                }
            )
            // The engine can't abort mid-flight, so a cancelled run still finishes its
            // frame — the compute is spent either way. KEEP the image (it used to be
            // silently discarded: user lost a finished render and saw nothing in the
            // gallery, with no log line either).
            resultImage = image
            previewImage = nil
            progress = 1
            etaSeconds = 0
            lastSeed = seed
            lastGenSeconds = genStart.map { Date().timeIntervalSince($0) }
            statusMessage = cancelledGen ? "Cancelled — the finished image was kept (see Gallery)" : "Done"
            await syncModelState()  // tier-aware: the pill answers "is MY tier resident?"
            sessionStats.generationCount += 1
            AppLog.info((cancelledGen ? "Cancelled after finish: " : "Done: ")
                        + "\(item.request.tier.displayName) · seed \(seed) · \(item.request.width)×\(item.request.height)"
                        + (item.request.loras.isEmpty ? ""
                           : " · LoRA " + item.request.loras.map(\.name).joined(separator: " + ")))
            // S-1: surface save failures instead of swallowing them with try?
            do {
                let gen = try await store.save(image: image, request: request, seed: seed, duration: lastGenSeconds)
                lastSavedURL = gen.imageURL
                lastSavedGenID = gen.id
                savedImageCount += 1   // live gallery refresh: monotonic, so .onChange always fires per queued image
                lastResultWasCancelled = cancelledGen   // a frame kept after Stop offers a one-tap delete
                return true   // image created AND saved → a real finished image
            } catch {
                // lastSavedURL was already cleared at the top — the canvas save/drag/upscale
                // can't silently export the WRONG image while the user tries to rescue this one.
                errorMessage = "Image created but couldn't be saved: \(error.localizedDescription)"
                return false
            }
        } catch is CancellationError {
            statusMessage = "Cancelled"
            previewImage = nil
            progress = 0   // a partial progress value must not read as "done · 100%" on the rail
            await syncModelState()  // C-4
            return false
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Error"
            previewImage = nil
            progress = 0   // ditto — a failed render is not 100% done
            await syncModelState()  // C-4: 19 GB not locked without unload button
            AppLog.error("Generation error: \(error.localizedDescription)")
            return false
        }
    }

    /// Auto-unload: a generation just finished — if the user walks away, release the ~9–19 GB
    /// the resident model holds. Any new generation cancels the timer; manual unload too.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        guard isModelLoaded || residentTier != nil else { return }
        let epoch = generationEpoch
        idleUnloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleUnloadMinutes * 60))
            // !isDescribing is load-bearing (re-checked after the actor hop below): a VLM
            // describe holds the global MLX pool but isn't a generation, so isBusy is false.
            guard !Task.isCancelled, let self, !self.isBusy, !self.isDescribing,
                  epoch == self.generationEpoch else { return }
            // Ask the ENGINE, not isModelLoaded: after a tier switch the pill goes false
            // while the other tier's weights are still resident — those must still be freed.
            guard await self.engine.isLoaded else { return }
            // Re-check the epoch after the actor hop too: a generation that started in the
            // gap shouldn't have its status overwritten (the engine's busy guard already
            // protects the weights themselves).
            if await self.engine.freeMemory(), epoch == self.generationEpoch, !self.isBusy, !self.isDescribing {
                self.isModelLoaded = false
                self.residentTier = nil
                self.statusMessage = "Model auto-unloaded after \(Self.idleUnloadMinutes) min idle"
                AppLog.info("Model auto-unloaded after \(Self.idleUnloadMinutes) min idle")
            }
        }
    }

    /// Stop the run after the current frame (the engine has no mid-step abort — with 4 Klein
    /// steps that's within ~1 step). The finished frame is KEPT; remaining tasks stay queued so
    /// "Run all" resumes them. (#11 — Stop no longer drops the user's composed list.)
    func cancel() {
        guard queueRunning else { return }
        cancelledGen = true
        // #11 The image already rendering can't be interrupted (the engine's GPU step is a
        // blocking call) — say so honestly instead of promising a stop that never lands.
        let pending = max(0, queue.count - 1)
        statusMessage = pending > 0
            ? "The current image can't be interrupted — it'll finish, then stop. \(pending) task(s) kept for Run all."
            : "The current image can't be interrupted — it'll finish, then stop."
        AppLog.info("Run stop requested — current image runs to completion; \(pending) kept")
    }

    /// Discard the image now on the canvas (used to throw away a frame kept after Stop, #11).
    func deleteLastResult() {
        guard let id = lastSavedGenID else { return }
        let thumbName = lastSavedURL?.lastPathComponent   // capture before clearing — to drop its thumbnail too
        resultImage = nil
        lastSavedURL = nil          // also triggers the gallery reload in ContentView
        lastSavedGenID = nil
        lastResultWasCancelled = false
        previewImage = nil
        statusMessage = "Deleted that image."
        Task {
            await store.delete(id)
            // Match the gallery delete paths — don't orphan the thumbnail cache file.
            if let thumbName {
                try? FileManager.default.removeItem(at: AppPaths.thumbnails.appendingPathComponent(thumbName))
            }
        }
        AppLog.info("Deleted the on-canvas result from the gallery")
    }

    /// C-1: sync isModelLoaded from the engine (call on appear so System-tab frees are
    /// reflected). Tier-aware: with two tiers, "loaded" means the CURRENTLY SELECTED tier
    /// is the resident one — after a switch the other tier's weights may still be in RAM,
    /// and the pill must not claim them as ours.
    func syncModelState() async {
        residentTier = await engine.loadedTier
        isModelLoaded = (residentTier == tier)
        modelMissing = !Flux2ModelDownloader.isDownloaded(.transformer(tier.transformerVariant))
        encoderMissing = !tier.isEncoderDownloaded
    }

    /// Load LoRAs compatible with the current tier (call on appear / tier change).
    func reloadLoRAs() {
        Task { @MainActor in
            let all = await loraStore.discover()
            self.allLoRAsOnDisk = all
            self.availableLoRAs = all.filter { $0.tier == self.tier }
            // Re-point each slot's selection to the fresh item (picks up trigger edits)
            // or clear it when the file is gone / no longer tier-compatible. Compact after:
            // a deletion may empty slot 0 while slot 1 still holds an adapter.
            for i in self.loraSlots.indices {
                if let sel = self.loraSlots[i].item {
                    self.loraSlots[i].item = self.availableLoRAs.first { $0.id == sel.id }
                }
            }
            self.compactLoRASlots()
        }
    }

    var isI2IMode: Bool { !references.isEmpty }

    // MARK: Aspect-ratio chips

    /// One-tap output formats. Every chip lands near Klein's ~1 MP sweet spot in the ratio's
    /// canonical orientation (4:5 portrait, 3:2 / 16:9 landscape) — the swap button flips it.
    static let aspectChips: [(label: String, w: Int, h: Int)] = [
        ("1:1", 1, 1), ("4:5", 4, 5), ("3:2", 3, 2), ("16:9", 16, 9), ("9:16", 9, 16)
    ]

    /// The chip's concrete pixel size: a /32-aligned size near Klein's ~1 MP sweet spot whose
    /// ratio is as close as possible to rw:rh. /32 (NOT /16) because the engine's VAE→CGImage
    /// row stride is width×3 and CoreGraphics aligns it to 32 bytes — a /16-but-not-/32 width
    /// (the old 9:16 = 720×1280) makes each scanline read off-by-16 → a clean horizontal tear.
    /// Searches /32 pairs in 512–1536 with area 0.85–1.10 MP, minimizing ratio error (larger
    /// area breaks ties). Yields 1:1=1024², 4:5=896×1120, 3:2=1248×832, 16:9=1312×736,
    /// 9:16=736×1312 — all /32, all <1.1 MP; 1:1/4:5/3:2 stay EXACT, 16:9/9:16 drift ≤0.27%.
    static func aspectSize(_ rw: Int, _ rh: Int) -> (width: Int, height: Int) {
        guard rw > 0, rh > 0 else { return (1024, 1024) }
        let target = Double(rw) / Double(rh)
        let grain = ReferenceSize.grain
        let lo = ReferenceSize.minSide, hi = ReferenceSize.maxSide
        let minArea = 850_000, maxArea = 1_100_000
        var best: (width: Int, height: Int)?
        var bestErr = Double.infinity
        var bestArea = 0
        var w = lo
        while w <= hi {
            var h = lo
            while h <= hi {
                let area = w * h
                if area >= minArea, area <= maxArea {
                    let err = abs(Double(w) / Double(h) - target)
                    if err < bestErr - 1e-9 || (abs(err - bestErr) < 1e-9 && area > bestArea) {
                        bestErr = err; bestArea = area; best = (w, h)
                    }
                }
                h += grain
            }
            w += grain
        }
        // Fallback for extreme ratios with no /32 pair in the sweet-spot area band.
        return best ?? (ReferenceSize.snapped(width: rw * 64, height: rh * 64) ?? (1024, 1024))
    }

    func applyAspect(_ rw: Int, _ rh: Int) {
        let size = Self.aspectSize(rw, rh)
        width = size.width
        height = size.height
    }

    /// Active when the form's current aspect RATIO matches the chip (within a small tolerance),
    /// not an exact pixel match: on <16 GB the RAM cap rewrites the form size after a render
    /// (preserving aspect), and an exact-size test would then wrongly de-highlight the chip.
    /// The ratio still distinguishes orientation (16:9 ≠ 9:16) and every chip (1:1/4:5/3:2).
    func aspectIsActive(_ rw: Int, _ rh: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let target = Double(rw) / Double(rh)
        let current = Double(width) / Double(height)
        // 0.03, not 0.02: the <16 GB RAM cap can drift 3:2 (1248×832) to 1088×736 — a 0.0217 ratio
        // shift that 0.02 wrongly de-highlighted. The smallest gap between chip ratios is ~0.20, so
        // 0.03 still can't cross-highlight a neighbouring aspect.
        return abs(current - target) < 0.03
    }

    func swapOrientation() {
        let w = width
        width = height
        height = w
    }

    // MARK: Remix — restore a stored recipe into the form

    /// Clear the on-canvas result + its action targets so a freshly-loaded recipe doesn't leave
    /// the PREVIOUS render live underneath — save/upscale/drag/to-I2I/pin-seed would act on it.
    private func clearResultState() {
        resultImage = nil
        previewImage = nil
        previewStep = 0
        lastSavedURL = nil
        lastSavedGenID = nil
        lastResultWasCancelled = false
        progress = 0
        etaSeconds = nil
        lastGenSeconds = nil
    }

    /// Apply a recipe's size, validated/clamped to Klein's range (snap if out of range or not
    /// /32). Returns a note when it had to adjust. Both recipe paths go through this so Remix
    /// can't push an unvalidated (or tearing /16-not-/32) size into the engine the way a
    /// hand-edited record could.
    private func applyRecipeSize(_ w: Int, _ h: Int) -> String? {
        let range = ReferenceSize.minSide ... ReferenceSize.maxSide
        if range.contains(w), range.contains(h), w % 32 == 0, h % 32 == 0 {
            width = w; height = h
            return nil
        }
        if let s = ReferenceSize.snapped(width: w, height: h) {
            width = s.width; height = s.height
            return "size \(w)×\(h) adjusted to \(s.width)×\(s.height) for Klein"
        }
        return "stored size \(w)×\(h) is invalid — kept \(width)×\(height)"
    }

    /// Gallery "Remix": load a record's full recipe (prompt with everything baked in, seed,
    /// size, tier, LoRA set, references) back into the form. Presets are CLEARED — their
    /// phrases are already inside the stored prompt and would double up. Missing files
    /// (deleted LoRA / moved reference) are skipped with an honest note.
    func applyRecipe(_ gen: Generation) async {
        errorMessage = nil   // a stale error would hide every confirmation/notice below (footer shows one)
        // Same gate as the tier chips: a mid-run tier flip desyncs the model pill, and
        // half-applying a recipe under a running queue only breeds confusion.
        guard !isBusy, !queueRunning else {
            statusMessage = "A render is running — finish or cancel it, then Remix."
            return
        }
        clearResultState()   // the recipe describes a NEW pending render — drop the old result
        var notes: [String] = []
        if let t = ModelTier(rawValue: gen.modelTier) {
            tier = t   // didSet no-ops when unchanged; otherwise persists + reloads LoRA list
        } else {
            notes.append("unknown model \u{201C}\(gen.modelTier)\u{201D} — kept \(tier.shortName)")
        }
        prompt = gen.prompt
        seedText = String(gen.seed)
        clearPresets()
        clearReferences()
        let refPaths = gen.referenceImagePaths ?? gen.referenceImagePath.map { [$0] } ?? []
        var missingRefs = 0
        for path in refPaths {
            if FileManager.default.fileExists(atPath: path) {
                // snapToFirst:false — refs are appended asynchronously (off-main decode), so the
                // first one's auto-snap would land AFTER applyRecipeSize and overwrite the recipe's
                // stored size. The recipe's size must win.
                addReference(from: URL(fileURLWithPath: path), snapToFirst: false)
            } else {
                missingRefs += 1
            }
        }
        if missingRefs > 0 {
            notes.append("\(missingRefs) reference\(missingRefs > 1 ? "s" : "") no longer on disk")
        }
        // Size AFTER references — the first reference auto-snaps dims, the recipe's size wins.
        // Validated like the PNG-drop path (a hand-edited record could carry a bad size).
        if let note = applyRecipeSize(gen.width, gen.height) { notes.append(note) }
        // The async ref appends haven't run yet (references is still empty here), so gate on
        // refPaths (known synchronously): after a remix, removing the references restores the
        // RECIPE's size — not a reference-snapped one (snapToFirst:false above prevents the snap).
        if !refPaths.isEmpty { preReferenceSize = (width, height) }
        let uses = gen.loras
            ?? gen.loraName.map { [LoRAUse(path: "", name: $0, scale: gen.loraScale ?? 1.0)] }
            ?? []
        notes.append(contentsOf: await applyLoRAUses(uses))
        errorMessage = nil
        statusMessage = "Recipe loaded — review and press Generate"
            + (notes.isEmpty ? "" : ". Note: \(notes.joined(separator: "; "))")
        AppLog.info("Remix: recipe restored (seed \(gen.seed))")
    }

    /// Canvas drop: read the recipe embedded in a PNG (ours, or any A1111-schema file) and
    /// apply it through the same path as Remix. No recipe → explain instead of guessing.
    func applyDroppedRecipe(from url: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            errorMessage = nil   // a stale error would hide the notices/confirmation below (footer shows one)
            guard !isBusy, !queueRunning else {
                statusMessage = "A render is running — finish or cancel it, then drop the PNG again."
                return
            }
            guard let text = PNGMetadata.parameters(fromPNGAt: url) else {
                statusMessage = "No recipe inside \u{201C}\(url.lastPathComponent)\u{201D} — images made here carry one. To use it as a reference instead, drop it on the References box."
                return
            }
            let recipe = PNGMetadata.recipe(from: text)
            clearResultState()   // the dropped recipe describes a NEW pending render
            var notes: [String] = []
            if let model = recipe.modelName {
                if model.localizedCaseInsensitiveContains("klein 4b") {
                    tier = .klein4B
                } else if model.localizedCaseInsensitiveContains("klein 9b") {
                    tier = .klein9B
                } else {
                    notes.append("made with \u{201C}\(model)\u{201D} — rendering on \(tier.shortName)")
                }
            }
            if !recipe.prompt.isEmpty { prompt = recipe.prompt }
            seedText = recipe.seed.map(String.init) ?? ""
            clearPresets()
            clearReferences()
            if let w = recipe.width, let h = recipe.height {
                if let note = applyRecipeSize(w, h) { notes.append(note) }
            }
            if recipe.hadNegativePrompt {
                notes.append("negative prompt skipped (Klein doesn't use one)")
            }
            let uses = recipe.loras.map { LoRAUse(path: "", name: $0.name, scale: $0.scale) }
            notes.append(contentsOf: await applyLoRAUses(uses))
            errorMessage = nil
            statusMessage = "Recipe restored from \(url.lastPathComponent)"
                + (notes.isEmpty ? "" : ". Note: \(notes.joined(separator: "; "))")
            AppLog.info("Recipe restored from PNG: \(url.lastPathComponent)")
        }
    }

    /// Point the LoRA slots at library items matching the given uses (by file name, against
    /// the CURRENT tier's list). Returns notes for adapters that aren't available anymore.
    private func applyLoRAUses(_ uses: [LoRAUse]) async -> [String] {
        for i in loraSlots.indices {
            loraSlots[i].item = nil
            loraSlots[i].scale = 1.0
        }
        guard !uses.isEmpty else { return [] }
        let all = await loraStore.discover()
        availableLoRAs = all.filter { $0.tier == tier }
        var notes: [String] = []
        var slot = 0
        var seen = Set<String>()
        for use in uses {
            guard slot < loraSlots.count else { break }
            // Dedupe by name: the engine fuses each adapter once, so filling both slots with
            // the same file would only mislead the footer (no double effect).
            guard seen.insert(use.name).inserted else { continue }
            if let item = availableLoRAs.first(where: { $0.fileName == use.name }) {
                loraSlots[slot].item = item
                // Clamp to the slider's range — a tampered/foreign recipe could carry any scale.
                loraSlots[slot].scale = min(max(use.scale, 0), 1.5)
                slot += 1
            } else {
                notes.append("LoRA \u{201C}\(use.name)\u{201D} isn't in the library — skipped")
            }
        }
        return notes
    }

    // MARK: Prompt presets

    /// Selected preset phrases assembled in BFL append order (style → shot → lighting → camera).
    /// Goes through PresetCatalog so the user's own chips participate too.
    var presetSuffix: String { PresetCatalog.suffix(for: selectedPresetIDs) }
    var hasPresets: Bool { !selectedPresetIDs.isEmpty }

    func togglePreset(_ id: String) {
        if selectedPresetIDs.contains(id) {
            selectedPresetIDs.remove(id)
            persistPresetSelection()
            return
        }
        selectPreset(id)
    }

    /// Idempotent select — used by toggle and by the LOOK bundles (a toggle would deselect
    /// chips a bundle shares with the current selection). Single-select categories replace
    /// their sibling; physically contradictory multi chips (hard sun ↔ overcast…) replace
    /// each other via the conflict map.
    func selectPreset(_ id: String) {
        if let category = PresetCatalog.category(for: id), !category.allowsMultiple {
            let siblings = Set(PresetCatalog.presets(for: category).map(\.id))
            selectedPresetIDs.subtract(siblings)
        }
        if let conflicting = PromptPresets.conflicts[id] {
            selectedPresetIDs.subtract(conflicting)
        }
        selectedPresetIDs.insert(id)
        persistPresetSelection()
    }

    /// A LOOK bundle is "active" when every one of its chips is selected.
    func bundleIsActive(_ bundle: PresetBundle) -> Bool {
        Set(bundle.chipIDs).isSubset(of: selectedPresetIDs)
    }

    /// Apply a LOOK: clear current selection, then set the bundle's chips (re-tap clears).
    /// Chips the user hid via right-click are unhidden first — hidden ids are filtered out
    /// of the prompt assembly, so leaving them hidden would silently break the look.
    func applyBundle(_ bundle: PresetBundle) {
        if bundleIsActive(bundle) {
            clearPresets()
            return
        }
        CustomPresetStore.shared.unhide(bundle.chipIDs)
        selectedPresetIDs.removeAll()
        for id in bundle.chipIDs { selectPreset(id) }
    }

    func clearPresets() {
        selectedPresetIDs.removeAll()
        persistPresetSelection()
    }

    /// One-tap from the Library: seed the recipe's example subject into the prompt and apply its
    /// chips. Styling lives entirely in the chips (centrally updatable) — no baked prompt string,
    /// so a chip phrase edit can never make a scene drift. The honest `note` becomes the status
    /// line (the per-scene capability honesty). Returns false if a render is running.
    @discardableResult
    func loadScene(_ recipe: SceneRecipe) -> Bool {
        errorMessage = nil
        // A scene is text-to-image: drop any leftover I2I references (and their size snap) so that
        // tapping a scene then pressing Generate can't silently run an I2I off a stale reference.
        // (enqueueScene already forces refs empty for the QUEUE path — this is the matching fix for
        // the tap-card → Generate path, mirroring Remix / PNG-drop which also clear on load.)
        clearReferences()
        // While a render runs, the canvas belongs to it — load the scene into the FORM only (so the
        // user can tweak it and Add to queue) without wiping the in-flight preview. The running render
        // already snapshotted its inputs, so changing the form can't disturb it. (#queue-presets: the
        // old hard block here was exactly the "can't queue the next preset during a render" report.)
        let running = isBusy || queueRunning
        if !running { clearResultState() }   // idle: a scene describes a NEW pending render — drop the old result
        prompt = recipe.subjectExample
        selectedPresetIDs.removeAll()
        CustomPresetStore.shared.unhide(recipe.chipIDs)   // hidden ids drop out of the prompt assembly
        for id in recipe.chipIDs { selectPreset(id) }     // selectPreset persists + honors single-select/conflicts
        statusMessage = running
            ? "Scene loaded into the form — press Add to queue. " + recipe.note
            : "Scene loaded — edit the subject, then Generate. " + recipe.note
        AppLog.info("Scene loaded\(running ? " (during a render)" : ""): \(recipe.id)")
        return true
    }

    /// Deselect one chip AND persist — the hide/delete context menus used to mutate
    /// `selectedPresetIDs` directly, losing the removal on quit (it came back selected).
    func deselectPreset(_ id: String) {
        selectedPresetIDs.remove(id)
        persistPresetSelection()
    }

    /// Selection survives relaunches (tiny, lives in UserDefaults).
    private func persistPresetSelection() {
        UserDefaults.standard.set(Array(selectedPresetIDs), forKey: Self.presetSelectionKey)
    }

    /// Live word count of prompt + appended preset phrases. Klein's encoder caps at 512
    /// tokens and ~40–70 words is the sweet spot — the counter goes green inside that band.
    var promptWordCount: Int {
        (prompt + " " + presetSuffix)
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
            .count
    }
    var promptIsLong: Bool { promptWordCount > 70 }

    /// Whether the Klein 9B transformer is present on disk (drives the model-status pill).
    var isModelDownloaded: Bool {
        Flux2ModelDownloader.isDownloaded(.transformer(tier.transformerVariant))
    }

    /// Export a copy of the current result to a user-chosen location (canvas "save").
    /// Prefers copying the gallery file — byte-identical AND keeps the embedded recipe;
    /// re-encoding from the CGImage (the fallback) would strip the tEXt chunk.
    func saveResultAs() {
        guard let img = resultImage else { return }
        let panel = NSSavePanel()
        panel.title = "Save image"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "typhoonminigen_\(lastSeed.map(String.init) ?? "image").png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fm = FileManager.default
            if let src = lastSavedURL, fm.fileExists(atPath: src.path) {
                // Saving INTO the gallery folder over the original would copy the file onto
                // itself — permanently destroying the only copy. APFS is case-insensitive, so
                // compare case-insensitively (foo.png == FOO.png are the same file).
                guard url.standardizedFileURL.path.caseInsensitiveCompare(src.standardizedFileURL.path) != .orderedSame else {
                    errorMessage = nil   // don't let a stale error hide this notice
                    statusMessage = "That IS the gallery original — pick a different folder or name."
                    return
                }
                // Copy to a temp sibling, then atomically swap in — a failed copy can no
                // longer lose the file the user chose to overwrite.
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmsave-\(UUID().uuidString).png")
                do {
                    try fm.copyItem(at: src, to: tmp)
                    if fm.fileExists(atPath: url.path) {   // the panel already confirmed replacing
                        _ = try fm.replaceItemAt(url, withItemAt: tmp)
                    } else {
                        try fm.moveItem(at: tmp, to: url)
                    }
                } catch {
                    try? fm.removeItem(at: tmp)
                    throw error
                }
                errorMessage = nil
                statusMessage = "Saved to \(url.lastPathComponent)"
            } else {
                // No gallery original on disk → re-encode the in-memory pixels. The recipe
                // metadata lives ONLY in the gallery PNG, so this copy has none — say so.
                let rep = NSBitmapImageRep(cgImage: img)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    errorMessage = "Couldn't encode the image as PNG."
                    return
                }
                try data.write(to: url, options: .atomic)
                errorMessage = nil
                statusMessage = "Saved to \(url.lastPathComponent) (no recipe metadata — the gallery copy is gone)"
            }
            AppLog.info("Image saved: \(url.lastPathComponent)")
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
            AppLog.error("Image save failed: \(error.localizedDescription)")
        }
    }

    /// Real-ESRGAN ×2/×4 on the saved result; reveals the new file in Finder when done.
    func upscaleResult(scale: Int) {
        guard let src = lastSavedURL, !isUpscaling else { return }
        guard FileManager.default.fileExists(atPath: src.path) else {
            // The result was deleted from the gallery after generating.
            lastSavedURL = nil
            errorMessage = "That image was deleted from the gallery — generate a new one first."
            return
        }
        isUpscaling = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let out = try await UpscaleService.upscale(src, scale: scale,
                    onStatus: { msg in Task { @MainActor in self.statusMessage = msg } })
                // No auto-reveal in Finder: the focus-steal made users open the PNG by
                // accident (the «Preview opens by itself» report). Gallery has a Finder button.
                self.statusMessage = "Upscaled ×\(scale) — saved next to the original (\(out.lastPathComponent))"
                AppLog.info("Upscaled ×\(scale): \(out.lastPathComponent)")
            } catch {
                self.errorMessage = "Upscale failed: \(error.localizedDescription)"
                AppLog.error("Upscale: \(error.localizedDescription)")
            }
            self.isUpscaling = false
        }
    }

    /// Pin the last result's seed into the Seed field (canvas "pin seed") so follow-up
    /// renders iterate on the same composition instead of rolling a new one.
    func pinLastSeed() {
        guard let seed = lastSeed else { return }
        seedText = String(seed)
        errorMessage = nil   // a stale error would hide this confirmation (footer shows one or the other)
        statusMessage = "Seed \(seed) pinned — clear the Seed field to go random again"
    }

    /// Feed the just-generated image back in as another I2I reference (canvas "to I2I").
    func useResultAsReference() {
        guard let img = resultImage else { return }
        guard references.count < Self.maxReferences else {
            errorMessage = nil
            statusMessage = "\(Self.maxReferences) references max"
            return
        }
        appendReference(img, url: lastSavedURL)
    }

    /// Opens an NSOpenPanel to pick reference images for I2I (up to the remaining free slots).
    func selectReferenceImages() {
        let panel = NSOpenPanel()
        panel.title = "Choose reference images"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        // Only the FIRST selected image may set the generation size — the per-file decodes run
        // concurrently, so leaving snapToFirst on all of them snapped to whichever decoded first,
        // not the one the user picked first.
        for (i, url) in panel.urls.enumerated() { addReference(from: url, snapToFirst: i == 0) }
    }

    /// Pick any PNG made here and restore its recipe — prompt, seed, size, model, LoRA — into
    /// the form. Routes through applyDroppedRecipe so it shares the busy guard, the size
    /// validation, and the honest "no recipe inside" message.
    func importRecipeFromPNG() {
        let panel = NSOpenPanel()
        panel.title = "Import recipe from a PNG"
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        applyDroppedRecipe(from: url)
    }

    /// Load one reference from disk into a free slot. Decoded DOWNSAMPLED to ≤1448 px on the
    /// long side (~2 MP ≈ 8 MB RGBA): the engine shrinks references to ≤1024² area anyway, so
    /// keeping more pixels in memory (queue items retain these images) buys nothing.
    func addReference(from url: URL, snapToFirst: Bool = true) {
        guard references.count < Self.maxReferences else {
            errorMessage = nil
            statusMessage = "\(Self.maxReferences) references max"
            return
        }
        // Decide the size-snap NOW (synchronously, in call order) rather than after the async decode,
        // where concurrent multi-file decodes finish out of order. `snapToFirst` marks the chosen
        // file; we snap only if it's also the first reference (an empty list at call time).
        let shouldSnap = snapToFirst && references.isEmpty
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Decode/downsample OFF the main thread — a large source photo would otherwise
            // hitch the UI while it's read and shrunk.
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1448
                ] as CFDictionary)
            }.value
            guard let cg else {
                // Undecodable / unsupported file — say so instead of a dead, silent drop.
                self.errorMessage = "Couldn't read \u{201C}\(url.lastPathComponent)\u{201D} — unsupported or damaged image."
                return
            }
            // Re-check capacity: several files decode concurrently; the appends land here serialized.
            guard self.references.count < Self.maxReferences else { return }
            self.appendReference(cg, url: url, snapToFirst: shouldSnap)
        }
    }

    /// Load a reference from raw image DATA — a drag from Photos / a browser carries data, not a
    /// file URL. Same downsample (≤1448 px) and capacity rules as addReference(from:). `url` is the
    /// on-disk path when the bytes came from a Finder/Desktop file (decoded from DATA for
    /// reliability, but the URL is kept so buildRequest records it in the recipe); nil for
    /// Photos/browser drags that have no file.
    func addReference(fromImageData data: Data, url: URL? = nil, snapToFirst: Bool = true) {
        guard references.count < Self.maxReferences else {
            errorMessage = nil
            statusMessage = "\(Self.maxReferences) references max"
            return
        }
        let shouldSnap = snapToFirst && references.isEmpty   // decide before the async decode (see addReference(from:))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1448
                ] as CFDictionary)
            }.value
            guard let cg else {
                self.errorMessage = "Couldn't read the dropped image — unsupported or damaged."
                return
            }
            guard self.references.count < Self.maxReferences else { return }
            self.appendReference(cg, url: url, snapToFirst: shouldSnap)
        }
    }

    private func appendReference(_ img: CGImage, url: URL?, snapToFirst: Bool = true) {
        // The snap decision is made SYNCHRONOUSLY at call time (see addReference) so it survives
        // concurrent off-main decode: with several files the first-PICKED may not be the first to
        // decode, and a `references.isEmpty` test here would then snap to the wrong file (or none).
        if snapToFirst { snapSize(toReference: img) }
        references.append(ReferenceSlot(image: img, url: url))
    }

    /// Match the generation size to the FIRST reference's aspect, CLAMPED to 512–1536 and
    /// rounded to /16. A raw 12 MP photo must never set a 12 MP generation — output latents
    /// scale quadratically and the engine has no working size guard (its hard stop is dead code).
    private func snapSize(toReference img: CGImage) {
        guard let snapped = ReferenceSize.snapped(width: img.width, height: img.height) else { return }
        if preReferenceSize == nil { preReferenceSize = (width, height) }
        width = snapped.width
        height = snapped.height
    }

    /// Qwen3.5-VLM 4B looks at every reference and APPENDS its description to the prompt
    /// editor — visible and editable, so the user stays in control of what gets generated.
    func describeReferences() {
        // Also gate on queueRunning: runAll() sets queueRunning synchronously while the engine's
        // busy/describing flags only flip after an async hop, so without this a user could press
        // Run-all then immediately Describe, launching the VLM concurrently with a denoise/VAE-decode
        // on the shared global MLX/Metal pool (buffer corruption / SIGABRT).
        guard !references.isEmpty, !isBusy, !queueRunning, !isDescribing else { return }
        isDescribing = true
        idleUnloadTask?.cancel()   // the VLM holds the global MLX pool — don't let the 15-min idle timer clear it mid-describe
        errorMessage = nil
        let imgs = references.map(\.image)
        let userContext = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.info("VLM describe started: \(imgs.count) reference(s)")
        describeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Tell the engine a describe is in flight so freeMemory()/Clear-cache (any tab)
            // refuse to tear down the global MLX pool under the running VLM inference. If the
            // engine is mid-unload or generating RIGHT NOW (a freeMemory()/Clear-cache from any
            // tab sets no VM flag this button could see), it refuses — bail instead of loading the
            // VLM into a pool being torn down (the unload→Describe race).
            guard await self.engine.setDescribing(true) else {
                self.isDescribing = false
                self.statusMessage = "Busy right now — try Describe again in a moment."
                self.scheduleIdleUnload()
                return
            }
            do {
                let texts = try await DescribeService.describe(
                    images: imgs,
                    context: userContext.isEmpty ? nil : userContext,
                    onStatus: { msg in Task { @MainActor in self.statusMessage = msg } }
                )
                // Cancel can land during the LAST image's inference, after which describe
                // returns normally — honor it instead of reporting success.
                try Task.checkCancellation()
                let block = texts.enumerated()
                    .map { texts.count > 1 ? "Reference \($0.offset + 1): \($0.element)" : $0.element }
                    .joined(separator: "\n")
                self.prompt += (self.prompt.isEmpty ? "" : "\n") + block
                self.statusMessage = "Description added to the prompt — edit it freely"
                AppLog.info("VLM described \(imgs.count) reference(s)")
            } catch is CancellationError {
                self.statusMessage = "Describe cancelled"
                AppLog.info("VLM describe cancelled by user")
            } catch {
                self.errorMessage = "Describe failed: \(error.localizedDescription)"
                self.statusMessage = ""
                AppLog.error("VLM describe: \(error.localizedDescription)")
            }
            await self.engine.setDescribing(false)
            self.isDescribing = false
            self.scheduleIdleUnload()   // re-arm the idle timer now that the VLM has released the pool
        }
    }

    /// Stop the VLM describe (it used to be impossible to abort — a stuck describe latched
    /// `isDescribing` and disabled Generate until relaunch). Takes effect at the next image
    /// boundary; the model download aborts immediately.
    func cancelDescribe() {
        describeTask?.cancel()
        statusMessage = "Cancelling describe…"
    }

    func removeReference(_ id: ReferenceSlot.ID) {
        references.removeAll { $0.id == id }
        if references.isEmpty { restorePreReferenceSize() }
    }

    func clearReferences() {
        references.removeAll()
        restorePreReferenceSize()
    }

    private func restorePreReferenceSize() {
        if let prior = preReferenceSize {
            preReferenceSize = nil   // first — so the restored size persists as the draft size
            width = prior.width
            height = prior.height
        }
    }

    func clearPreview() {
        resultImage = nil
        progress = 0
        etaSeconds = nil
        lastGenSeconds = nil
        statusMessage = ""
    }

    /// Unload the resident model and clear MLX caches to reclaim RAM (feature: free memory).
    func freeMemory() {
        idleUnloadTask?.cancel()
        Task { @MainActor in
            self.errorMessage = nil
            self.statusMessage = "Unloading model…"
            let freed = await self.engine.freeMemory()
            if freed {
                self.isModelLoaded = false
                self.residentTier = nil
                self.statusMessage = "Memory freed"
            } else {
                self.statusMessage = self.isDescribing
                    ? "Describing a reference — unload deferred until it finishes."
                    : "Generation in progress — unload deferred."
            }
        }
    }

    // NB: no "Step N/M" status here — the visible status line is for EVENTS (queued /
    // saved / unloaded…); live step progress already renders in the rail, canvas and header.
    private func updateProgress(current: Int, total: Int) {
        guard total > 0 else { return }
        // Denoise is running — retire the stale "Preparing…"/"Image X of Y…" line (the
        // rail, canvas and header carry the live progress from here). NOT when the user
        // just cancelled: "Cancelling…" must stay visible until the frame finishes.
        if current == 1, !cancelledGen { statusMessage = "" }
        currentStep = current
        progress = Double(current) / Double(total)
        if let start = genStart, current > 0 {
            let perStep = Date().timeIntervalSince(start) / Double(current)
            etaSeconds = perStep * Double(total - current)
        }
    }
}
