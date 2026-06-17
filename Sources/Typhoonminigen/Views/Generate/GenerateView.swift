import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Wraps an `NSItemProvider` so it can be captured inside another load completion (a `@Sendable`
/// closure). `NSItemProvider`'s `load*` methods are documented thread-safe but the type isn't
/// `Sendable`; this is the narrow, honest escape — we only call those thread-safe methods on it.
private struct SendableProvider: @unchecked Sendable {
    let provider: NSItemProvider
    init(_ provider: NSItemProvider) { self.provider = provider }
}

/// Generation screen — controls (360) · result canvas (flex) · telemetry rail (220).
struct GenerateView: View {
    @Bindable var vm: GenerateViewModel
    @Bindable var telemetry: TelemetryService
    var railVisible: Bool = true   // toggled from the titlebar (mirrors the sidebar)
    var openModels: () -> Void = {}   // canvas CTA → Models tab (ContentView owns the section)
    var openQueue: () -> Void = {}    // footer link → Queue tab (#1 scheduler)
    @State private var recipeDropTargeted = false
    @AppStorage("panelsCollapsed") private var panelsCollapsed = false   // #7 hide the panels under the prompt
    @State private var resultZoom: CGFloat = 1        // #14 scroll-wheel zoom of the result preview
    @State private var resultPan: CGSize = .zero      // #14 pan offset that keeps the point under the cursor fixed
    @State private var resultImageFrame: CGRect = .zero  // the fitted (unscaled) image rect, global coords
    @State private var canvasFrame: CGRect = .zero    // canvas bounds in global coords, for the scroll monitor
    @State private var scrollMonitor: Any? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollViewReader { proxy in
                ScrollView { controls.padding(.trailing, 2).id("controls-top") }
                    .frame(width: 360)
                    // #5 collapse was invisible when scrolled down — snap back to the prompt.
                    .onChange(of: panelsCollapsed) { _, collapsed in
                        if collapsed { withAnimation { proxy.scrollTo("controls-top", anchor: .top) } }
                    }
            }
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if railVisible {
                ScrollView { rail }
                    .frame(width: 250)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.fxBg)
        .onAppear { installScrollZoom() }
        .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil } }
        .onChange(of: vm.isBusy) { _, busy in if busy { resultZoom = 1; resultPan = .zero } }   // a new render resets zoom
        .task {
            await vm.syncModelState()
            vm.reloadLoRAs()
        }
    }

    // ════════════════════════════ COLUMN 1 — CONTROLS ════════════════════════════

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            modelCard
            promptCard
            if !panelsCollapsed {
                paramsCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
                PresetsSection(vm: vm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                ReferenceImageSection(vm: vm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            footer
        }
        // #5 belt-and-suspenders: also animate the panel show/hide off the panelsCollapsed VALUE,
        // so the collapse transitions fire even if the @AppStorage write-back lands in a separate
        // (un-animated) transaction from the chevron's withAnimation — it never silently pops.
        .animation(.easeInOut(duration: 0.18), value: panelsCollapsed)
    }

    private var modelStatusText: String {
        if vm.isModelLoaded { return "in memory" }
        return vm.isModelDownloaded ? "on disk" : "not downloaded"
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                FxDot(tone: vm.isModelLoaded ? .ok : .idle, live: vm.isModelLoaded)
                Text("Model").foregroundColor(.fxText)
                    .font(.fx(14, weight: .bold))
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    FxDot(tone: vm.isModelLoaded ? .ok : .idle, size: 6)
                    Text(modelStatusText)
                }
                .font(.fxMono(10.5))
                .foregroundStyle(vm.isModelLoaded ? Color.fxOk : Color.fxText3)
                .padding(.vertical, 3).padding(.horizontal, 9)
                .background(vm.isModelLoaded ? Color.fxOkSoft : Color.fxInset,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(vm.isModelLoaded ? Color.fxOkSoft : Color.fxBorder, lineWidth: 1))
                .help("Model state: \u{201C}in memory\u{201D} = next render starts instantly; \u{201C}on disk\u{201D} = loads on the next render (~1 min); \u{201C}not downloaded\u{201D} = get it in the Models tab.")
            }
            HStack(spacing: 6) {
                ForEach(ModelTier.allCases) { t in
                    tierChip(t)
                }
            }
            Text(tierBlurb)
                .font(.fx(11.5)).foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            if vm.tier == .klein9B && vm.ramGB < 24 {
                Text("Klein 9B peaks at ~19–20 GB — on this \(vm.ramGB) GB Mac it WILL swap and may freeze the system. Use Klein 4B here.")
                    .font(.fx(11, weight: .semibold)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if vm.tier == .klein9B && vm.ramGB < 32 {
                Text("Klein 9B is tight on a \(vm.ramGB) GB Mac (~19–20 GB peak + macOS) — it runs, but expect slowdowns. Klein 4B is the smooth choice.")
                    .font(.fx(11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if vm.tier == .klein4B && vm.ramGB < 16 {
                Text("This Mac has \(vm.ramGB) GB RAM. Above ~0.8 MP the final VAE step runs out of GPU memory and aborts, so sizes are auto-capped to ~896×896 on this Mac. A 16 GB+ Mac unlocks 1024×1024.")
                    .font(.fx(11, weight: .semibold)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard()
    }

    private var tierBlurb: String {
        switch vm.tier {
        case .klein4B:
            return "Klein 4B: light tier — ~4 GB download + ~4 GB encoder, no token, Apache 2.0. Made for 16–24 GB Macs; ~1 min per 1024² image, somewhat simpler detail."
        case .klein9B:
            return "Klein 9B: quality tier — ~19 GB peak (fits 32 GB without swap), gated — needs an HF token in the Models tab."
        }
    }

    /// Tier selector chip. Disabled while generating: queued items keep their snapshotted
    /// tier anyway, and mid-run switches would only desync the status pill.
    private func tierChip(_ t: ModelTier) -> some View {
        let active = vm.tier == t
        return Button { vm.tier = t } label: {
            Text(t.shortName)
                .font(.fxMono(11.5))
                .foregroundStyle(active ? Color.fxOnAccent : Color.fxText2)
                .padding(.vertical, 5).padding(.horizontal, 12)
                .background(active ? Color.fxAccent : Color.fxInset,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? Color.fxAccent : Color.fxBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy || vm.queueRunning)
        .opacity((vm.isBusy || vm.queueRunning) && !active ? 0.5 : 1)
        .help(t == .klein4B
              ? "Light model: ~8 GB disk total, no HuggingFace token, Apache 2.0"
              : "Quality model: ~26 GB disk total, needs a HuggingFace token (gated)")
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Prompt").font(.fx(12, weight: .semibold)).foregroundStyle(Color.fxText2)
                Text("any language").font(.fx(11)).foregroundStyle(Color.fxText3)
                Spacer()
                Button { vm.importRecipeFromPNG() } label: {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Color.fxText3)
                .help("Import recipe from a PNG — restores the prompt, seed, size, model and LoRA from any image made here.")
                Button { withAnimation(.easeInOut(duration: 0.18)) { panelsCollapsed.toggle() } } label: {
                    Image(systemName: panelsCollapsed ? "chevron.down" : "chevron.up").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Color.fxText3)
                .help(panelsCollapsed ? "Show the settings below the prompt (size, presets, references)"
                                      : "Hide the settings below the prompt (size, presets, references)")
                // Live prompt+chips size against Klein's 40–70-word sweet spot:
                // gray below, green inside, amber past it.
                Text("≈ \(vm.promptWordCount) words")
                    .font(.fxMono(10.5)).foregroundStyle(wordCountColor)
                    .help("Prompt plus selected preset phrases. Klein renders best at 40–70 words.")
            }
            ZStack(alignment: .topLeading) {
                if vm.prompt.isEmpty {
                    Text("Describe what to generate…")
                        .font(.fx(12.5)).foregroundStyle(Color.fxText3)
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.prompt)
                    .font(.fx(12.5))
                    .foregroundStyle(Color.fxText)
                    .scrollContentBackground(.hidden)
                    .lineSpacing(3)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    // #5 grows to fill the freed space when the panels are hidden — a clear
                    // visual confirmation that the collapse actually happened.
                    .frame(minHeight: panelsCollapsed ? 340 : 120)
            }
            .fxInsetField(radius: 10)
            .help("Describe the image in any language. Selected preset phrases and LoRA trigger words are appended automatically at generation — you only write the subject.")
        }
        .fxCard()
    }

    private var wordCountColor: Color {
        if vm.promptWordCount > 70 { return .orange }
        if vm.promptWordCount >= 40 { return .fxOk }
        return .fxText3
    }

    private var paramsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            aspectRow
            HStack(spacing: 10) {
                FxStepper(label: "Width", value: $vm.width,
                          range: ReferenceSize.minSide...ReferenceSize.maxSide, step: 128)
                    .help("Output width in pixels — Klein renders best near a 1024×1024 area")
                FxStepper(label: "Height", value: $vm.height,
                          range: ReferenceSize.minSide...ReferenceSize.maxSide, step: 128)
                    .help("Output height in pixels — Klein renders best near a 1024×1024 area")
            }
            if vm.sizeIsLarge {
                Text("Above ~1.1 MP Klein quality degrades (deformations) — its sweet spot is the 1024×1024 area. Generate near 1 MP, then Upscale ×2/×4.")
                    .font(.fx(11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if vm.ramGB < 24 {
                    Text("A larger size also grows the final VAE memory spike — on a \(vm.ramGB) GB Mac it can swap or freeze.")
                        .font(.fx(11, weight: .semibold)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Seed").fxLabel()
                    TextField("random", text: $vm.seedText)
                        .textFieldStyle(.plain)
                        .font(.fxMono(12))
                        .foregroundStyle(vm.seedIsInvalid ? Color.red : Color.fxText)
                        .padding(.vertical, 7).padding(.horizontal, 11)
                        .fxInsetField(radius: 8)
                        .help("Empty = a new random seed every render. Paste a seed from the Gallery to reproduce an image exactly; a batch counts up from it.")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("LoRA").fxLabel()
                    loraMenu(0)
                    if vm.availableLoRAs.isEmpty, let other = vm.loRAsForOtherTier.first?.tier?.shortName {
                        let n = vm.loRAsForOtherTier.count
                        Text("You have \(n) adapter\(n == 1 ? "" : "s") for \(other). Switch the model to \(other) on the Models tab to use \(n == 1 ? "it" : "them").")
                            .font(.fx(11)).foregroundStyle(Color.fxAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if vm.loraSlots[0].item != nil {
                loraSlotDetails(0)
                // Second slot appears once the first is in use — the engine fuses both
                // and their effects combine (e.g. a style LoRA + a subject LoRA).
                VStack(alignment: .leading, spacing: 5) {
                    Text("LoRA 2 (optional — effects combine)").fxLabel()
                    loraMenu(1)
                }
                if vm.loraSlots[1].item != nil {
                    loraSlotDetails(1)
                }
            }
            if vm.upsamplePrompt, !vm.isI2IMode, vm.activeLoRASlots.contains(where: { $0.item?.trigger.isEmpty == false }) {
                Text("Qwen3 may rephrase the LoRA trigger — check the result.")
                    .font(.fx(11)).foregroundStyle(.orange)
            }
        }
        .fxCard()
    }

    /// One-tap output formats — every chip lands on Klein's ~1 MP sweet spot, so the user
    /// never hand-dials a quality-degrading size; the ⇄ button flips portrait/landscape.
    private var aspectRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Aspect").fxLabel()
            HStack(spacing: 6) {
                ForEach(GenerateViewModel.aspectChips, id: \.label) { chip in
                    aspectChip(chip)
                }
                Spacer(minLength: 0)
                Button { vm.swapOrientation() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.fxText2)
                        .padding(.vertical, 6).padding(.horizontal, 9)
                        .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.fxBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Swap width and height (portrait ↔ landscape)")
            }
        }
    }

    private func aspectChip(_ chip: (label: String, w: Int, h: Int)) -> some View {
        let active = vm.aspectIsActive(chip.w, chip.h)
        let size = GenerateViewModel.aspectSize(chip.w, chip.h)
        return Button { vm.applyAspect(chip.w, chip.h) } label: {
            Text(chip.label)
                .font(.fxMono(11))
                .foregroundStyle(active ? Color.fxOnAccent : Color.fxText2)
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(active ? Color.fxAccent : Color.fxInset,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? Color.fxAccent : Color.fxBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("\(size.width)×\(size.height)\(chip.w == chip.h ? "" : (chip.w < chip.h ? " — portrait" : " — landscape")) · ⇄ flips it · all chips target Klein's ~1 MP sweet spot")
    }

    private func loraMenu(_ index: Int) -> some View {
        // The other slot's selection is excluded — fusing the same file twice doubles it.
        let otherID = vm.loraSlots[1 - index].item?.id
        return Menu {
            Button(index == 0 ? "No LoRA" : "None") { vm.clearLoRASlot(index) }
            ForEach(vm.availableLoRAs.filter { $0.id != otherID }) { lora in
                Button(lora.fileName) { vm.loraSlots[index].item = lora }
            }
        } label: {
            HStack {
                Text(vm.loraSlots[index].item?.fileName ?? (index == 0 ? "No LoRA" : "None"))
                    .font(.fx(12.5)).foregroundStyle(Color.fxText).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(Color.fxText3)
            }
            .padding(.vertical, 7).padding(.horizontal, 11)
            .fxInsetField(radius: 8)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(vm.availableLoRAs.isEmpty)
        .help(vm.availableLoRAs.isEmpty
              ? (vm.loRAsForOtherTier.isEmpty
                 ? "No \(vm.tier.shortName)-compatible adapters — import one on the LoRA tab."
                 : "No adapters for \(vm.tier.shortName). The ones you have are built for the other tier — switch the model on the Models tab to use them.")
              : "Fuse a LoRA adapter into the next render. Changing the adapter set reloads clean model weights first — instant when cached, up to ~1 min from a cold disk. Manage adapters on the LoRA tab.")
    }

    /// Strength slider + trigger note for one selected LoRA slot.
    @ViewBuilder private func loraSlotDetails(_ index: Int) -> some View {
        if let lora = vm.loraSlots[index].item {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Strength").fxLabel()
                    Slider(value: $vm.loraSlots[index].scale, in: 0...1.5).tint(.fxAccent)
                    TextField("", text: Binding(
                        get: { String(format: "%.2f", vm.loraSlots[index].scale) },
                        set: { vm.loraSlots[index].scale = min(max(Float($0.replacingOccurrences(of: ",", with: ".")) ?? vm.loraSlots[index].scale, 0), 1.5) }
                    ))
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .font(.fxMono(11)).foregroundStyle(Color.fxText2)
                }
                .help("How strongly the adapter modifies the model — 1.00 = as trained. Changing it reloads clean weights before the next render.")
                if lora.trigger.isEmpty {
                    Text("No trigger set — add one on the LoRA tab if needed.")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                } else {
                    Text("Trigger “\(lora.trigger)” will be added to the prompt automatically.")
                        .font(.fx(11)).foregroundStyle(Color.fxAccent)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 11) {
            enhanceToggle
            previewModeRow

            if vm.hasPresets {
                (Text("+ adds: ").foregroundColor(.fxAccent) + Text(vm.presetSuffix).foregroundColor(.fxText3))
                    .font(.fxMono(10.5))
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            }
            if vm.promptIsLong {
                Text("Prompt is getting long — Klein works best under ~70 words.")
                    .font(.fx(11)).foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Text("\(vm.steps) steps")
                StatusSep()
                Text("guidance \(vm.guidance, specifier: "%.1f")")
                StatusSep()
                Text(vm.tier.license).lineLimit(1)
            }
            .font(.fxMono(11)).foregroundStyle(Color.fxText3)
            .help("Klein is a 4-step distilled model — steps and guidance are fixed at the values it was trained for; more steps would not improve quality.")

            HStack(spacing: 10) {
                FxStepper(label: "Batch (images per click)", value: $vm.batchCount, range: 1...8, step: 1)
                    .help("Queue this many variants per click — same prompt, sequential seeds. Different prompts: start one, rewrite, then \u{201C}Add to queue\u{201D}.")
            }

            // The single source of truth for "what fuses into the NEXT render" — right where
            // the user commits. Kills the "a LoRA styled my image by itself" confusion class.
            if !vm.activeLoRASlots.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 10))
                    Text("LoRA: " + activeLoRASummary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.fxMono(10.5)).foregroundStyle(Color.fxAccent)
                .help("Exactly these adapters fuse into the next render. Changing the set or a strength reloads clean model weights first — instant when the file is cached, up to ~1 min from a cold disk.")
            }

            Button { vm.generate() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").font(.system(size: 13))
                    Text(generateLabel)
                }
            }
            .buttonStyle(FxPrimaryButtonStyle(height: 40, fullWidth: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!vm.canGenerate)
            .opacity(vm.canGenerate ? 1 : 0.5)
            .help("⌘⏎ — render now with the current settings. During a run it joins the end of the queue and renders.")

            // Compose a batch without running it now (#1). The Queue tab runs them all.
            HStack(spacing: 10) {
                Button { vm.addTaskToQueue() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("Add to queue")
                    }.font(.fx(12))
                }
                .buttonStyle(FxGhostButtonStyle(height: 30, accentText: true))
                .disabled(!vm.canGenerate).opacity(vm.canGenerate ? 1 : 0.5)
                .help("Add this as a task WITHOUT running it — line up several different prompts, then open the Queue tab and Run all.")
                if !vm.queue.isEmpty {
                    Button { openQueue() } label: {
                        Text("\(vm.queue.count) in queue →").font(.fx(11.5)).foregroundStyle(Color.fxAccent)
                    }
                    .buttonStyle(.plain)
                    .help("Open the Queue tab to manage and run your tasks.")
                }
                Spacer(minLength: 0)
            }

            if vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Type a prompt first — the button activates when there's text.")
                    .font(.fx(10.5)).foregroundStyle(Color.fxText3)
            }

            if vm.isBusy {
                // #11 honest Stop: the image already rendering CANNOT be interrupted — the GPU
                // step is a blocking call the app can't cut off. Stop lets it finish (and keeps
                // it), and prevents any pending queued tasks from starting. The label and caption
                // say so plainly instead of promising a stop that never happens.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Stop after this image") { vm.cancel() }
                            .buttonStyle(FxGhostButtonStyle(height: 28, accentText: true))
                            .keyboardShortcut(.cancelAction)
                            .help("The image already rendering can't be interrupted — its GPU step can't be cut off. Stop lets it finish and keeps it; any pending queued tasks won't start. Esc.")
                        Spacer()
                        if let eta = vm.etaSeconds, eta > 0 {
                            Text(etaHuman(eta)).font(.fxMono(11)).foregroundStyle(Color.fxText3)
                        }
                    }
                    // Gate on actual pending work (the running item sits at queue[0], so >1 means
                    // at least one task is still waiting) — queueTotal is the run total and isn't
                    // decremented per image, so it would falsely promise "the queue stops" on the
                    // LAST image of a series when nothing is actually pending.
                    Text(vm.queue.count > 1
                         ? "Can't interrupt the current image — it finishes, then the queue stops (kept for Run all)."
                         : "Can't interrupt the current image — it will finish.")
                        .font(.fx(10.5)).foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if vm.queueRunning && vm.queueTotal > 1 {
                queuePanel
            }

            if let err = vm.errorMessage {
                Text(err).font(.fx(11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !vm.statusMessage.isEmpty {
                // The event feedback channel — "Added to queue", "Saved to…", "Upscaled ×2",
                // "Model auto-unloaded"… (it was set everywhere but rendered nowhere, which
                // is how "Add to queue doesn't work" reports happened).
                Text(vm.statusMessage).font(.fx(11)).foregroundStyle(Color.fxText2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // After a Stop, the finished-but-cancelled frame was kept + saved — offer to discard it (#11).
            if vm.lastResultWasCancelled, vm.resultImage != nil, !vm.isBusy {
                Button { vm.deleteLastResult() } label: {
                    Label("Delete this kept image", systemImage: "trash").font(.fx(11))
                }
                .buttonStyle(.plain).foregroundStyle(.red)
                .help("The run was stopped but the finished frame was saved to the gallery — remove it.")
            }

            // Keyed off the ENGINE's resident tier, not the selected one — after a tier
            // switch the other tier's ~4–19 GB stays in RAM and must remain unloadable.
            if let resident = vm.residentTier, !vm.isBusy {
                Button { vm.freeMemory() } label: {
                    Label("Unload \(resident.shortName) from memory", systemImage: "memorychip")
                        .font(.fx(11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.fxText3)
                .help("Free the ~4–19 GB the model holds in RAM — it stays on disk and reloads on the next render (~1 min)")
            }
        }
    }

    // #10 No morphing: "Generate" always means render now (it joins the end of a running queue).
    private var generateLabel: String {
        vm.batchCount > 1 ? "Generate ×\(vm.batchCount)" : "Generate"
    }

    private var activeLoRASummary: String {
        vm.activeLoRASlots.compactMap { slot in
            slot.item.map { "\($0.fileName) @ \(String(format: "%.2f", slot.scale))" }
        }.joined(separator: " + ")
    }

    /// Compact queue-row seed: full when short (user-typed), truncated for 20-digit randoms.
    private func seedBadge(_ seed: UInt64?) -> String {
        guard let s = seed else { return "" }
        let str = String(s)
        return str.count > 7 ? "s \(str.prefix(5))…" : "s \(str)"
    }

    /// Pending/running items list. The first row is the running one (amber, no ✕).
    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("QUEUE").font(.fx(10.5, weight: .semibold)).tracking(0.8).foregroundStyle(Color.fxText3)
                Spacer()
                Text("\(vm.queueDone) done · \(vm.queue.count) left")
                    .font(.fxMono(10)).foregroundStyle(Color.fxText3)
            }
            ForEach(vm.queue) { item in
                HStack(spacing: 7) {
                    FxDot(tone: item.id == vm.currentItemID ? .amber : .idle,
                          live: item.id == vm.currentItemID, size: 6)
                    Text(item.label)
                        .font(.fx(11))
                        .foregroundStyle(item.id == vm.currentItemID ? Color.fxText : Color.fxText2)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    // Seed visible per item — a fixed seed left in the field silently
                    // stamps every queued item with the same value (user-reported confusion).
                    Text(seedBadge(item.request.seed))
                        .font(.fxMono(9.5)).foregroundStyle(Color.fxText3)
                    Text("\(item.request.width)×\(item.request.height)")
                        .font(.fxMono(9.5)).foregroundStyle(Color.fxText3)
                    if item.id != vm.currentItemID {
                        Button { vm.removeQueued(item.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold)).foregroundStyle(Color.fxText3)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this pending item from the queue")
                    }
                }
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 11)
        .fxInsetField(radius: 10)
    }

    private var enhanceToggle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { vm.upsamplePrompt.toggle() } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(vm.upsamplePrompt ? Color.fxAccent : Color.fxInset)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(vm.upsamplePrompt ? Color.fxAccent : Color.fxBorderStrong, lineWidth: 1))
                        .overlay {
                            if vm.upsamplePrompt {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.fxOnAccent)
                            }
                        }
                        .frame(width: 16, height: 16)
                    (Text("Enhance prompt ").foregroundColor(.fxText2)
                     + Text("(Qwen3 adds detail)").foregroundColor(.fxText3))
                        .font(.fx(12.5))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.isI2IMode)
            .opacity(vm.isI2IMode ? 0.45 : 1)
            .help("Qwen3 rewrites the prompt with extra descriptive detail before rendering (runs locally). Ignored in I2I mode — with a reference it would load a 24 GB vision model. May rephrase LoRA trigger words.")
            // With a reference, the engine's "enhance" would load a 24 GB Mistral VLM —
            // it is forced off for I2I (see FluxEngine); tell the user why the box is inert.
            if vm.isI2IMode && vm.upsamplePrompt {
                Text("Ignored in I2I mode — enhancing with a reference would load a 24 GB vision model.")
                    .font(.fx(11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }


    /// Soft-focus the noisy early frames in "Every step" mode so they resolve into focus as
    /// the render progresses; the single "At ~75%" frame and the final step stay sharp (0 blur).
    private var previewBlurRadius: CGFloat {
        guard vm.previewEveryStep, vm.previewStep < vm.steps else { return 0 }
        let remaining = 1 - Double(vm.previewStep) / Double(max(1, vm.steps))   // step 1/4 → .75, 3/4 → .25
        return CGFloat(6 * remaining)
    }

    /// Live render preview as ONE explicit 3-state control. Hiding "Show every step" under a
    /// "Live preview" checkbox (it only appeared once the checkbox was ticked) left users asking
    /// "what is this?" — Off / At ~75% / Every step now read at a glance. The three chips map to
    /// (livePreview, previewEveryStep): Off=(false,_), At ~75%=(true,false), Every step=(true,true).
    private var previewModeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Live preview").fxLabel()
            HStack(spacing: 6) {
                previewModeChip("Off", live: false, every: false,
                                help: "No preview while rendering — fastest.")
                previewModeChip("At ~75%", live: true, every: false,
                                help: "One clean preview near the end (~75%), a few seconds slower.")
                previewModeChip("Every step", live: true, every: true,
                                help: "Show the image after every step (1/4…4/4). Early steps look noisy, like Draw Things — a bit slower.")
                Spacer(minLength: 0)
            }
        }
    }

    private func previewModeChip(_ label: String, live: Bool, every: Bool, help: String) -> some View {
        // "Off" is active whenever live preview is off, regardless of the every-step flag.
        let active = live ? (vm.livePreview && vm.previewEveryStep == every) : !vm.livePreview
        return Button {
            vm.livePreview = live
            if live { vm.previewEveryStep = every }
        } label: {
            Text(label)
                .font(.fx(11.5))
                .foregroundStyle(active ? Color.fxOnAccent : Color.fxText2)
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(active ? Color.fxAccent : Color.fxInset,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? Color.fxAccent : Color.fxBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // ════════════════════════════ COLUMN 2 — CANVAS ════════════════════════════

    private var canvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(RadialGradient(colors: [Color(hex: 0x1C1D21), Color(hex: 0x141518)],
                                     center: .top, startRadius: 0, endRadius: 700))
            canvasContent
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(recipeDropTargeted ? Color.fxAccent : Color.fxBorder,
                          lineWidth: recipeDropTargeted ? 1.5 : 1))
        .overlay {
            if recipeDropTargeted {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 12))
                    Text("Drop a PNG to restore its recipe")
                }
                .font(.fx(12, weight: .semibold)).foregroundStyle(Color.fxText)
                .padding(.vertical, 8).padding(.horizontal, 14)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.fxAccent, lineWidth: 1))
            }
        }
        // The canvas reads recipes back out of PNGs (the gallery writes one into every
        // image): prompt, seed, size, model and LoRA return to the form in one drop.
        // References have their own drop box — this one is about the RECIPE.
        .onDrop(of: [UTType.fileURL], isTargeted: $recipeDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    // The result's drag-OUT starts inside this same drop region — an
                    // aborted drag released over the canvas must not re-apply the
                    // image's own recipe over the user's edits.
                    if let own = vm.lastSavedURL,
                       url.standardizedFileURL.path == own.standardizedFileURL.path {
                        vm.statusMessage = "That image is already on the canvas — drop an older PNG, or use Remix in the Gallery."
                        return
                    }
                    vm.applyDroppedRecipe(from: url)
                }
            }
            return true
        }
        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 8)
        .frame(minWidth: 300, minHeight: 360)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { canvasFrame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { old, f in
                    canvasFrame = f
                    // Real window/layout resize — this reader is ABOVE .scaleEffect, so it does NOT
                    // fire on a scroll-zoom. The captured fit-rect is now stale, so snap back to a
                    // clean fit instead of letting zoom-toward-cursor drift.
                    if f.size != old.size, resultZoom != 1 || resultPan != .zero {
                        resultZoom = 1; resultPan = .zero
                    }
                }
        })
    }

    /// Drag the finished render out — to Finder, Telegram, an editor… The provider carries
    /// the saved gallery FILE (with its embedded recipe), not a re-encoded copy.
    private func resultDragProvider() -> NSItemProvider {
        guard let url = vm.lastSavedURL,
              FileManager.default.fileExists(atPath: url.path),
              let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    /// Scroll-wheel zoom for the result preview. A local monitor (not an overlay) so the image's
    /// drag-out and the controls column scrolling keep working — we only consume a scroll when the
    /// cursor is over the canvas and a result is shown.
    private func installScrollZoom() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard vm.resultImage != nil, !vm.isBusy, let window = event.window else { return event }
            let h = window.contentView?.bounds.height ?? window.frame.height
            let p = CGPoint(x: event.locationInWindow.x, y: h - event.locationInWindow.y)  // AppKit y-up → SwiftUI y-down
            guard canvasFrame.contains(p) else { return event }
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY / 12
            let newZoom = min(max(resultZoom * (1 + dy), 1), 6)
            // Zoom toward the cursor: re-solve the pan so the content point under the cursor Q
            // stays under it as the scale changes around the image centre C. At fit (1×) there's
            // no offset, so scrolling all the way back always lands on a clean centred image.
            let factor = newZoom / resultZoom
            if newZoom <= 1 || resultImageFrame.width <= 0 {
                resultPan = .zero
            } else {
                let cx = resultImageFrame.midX, cy = resultImageFrame.midY
                resultPan = CGSize(
                    width:  p.x - cx - factor * (p.x - cx - resultPan.width),
                    height: p.y - cy - factor * (p.y - cy - resultPan.height))
            }
            resultZoom = newZoom
            return nil   // consume so the controls column doesn't also scroll
        }
    }

    @ViewBuilder private var canvasContent: some View {
        if let img = vm.resultImage {
            ZStack {
                Image(decorative: img, scale: 1)
                    .resizable().scaledToFit()
                    .background(GeometryReader { geo in
                        Color.clear
                            // #4 capture the fitted rect ONLY at fit (zoom 1, no pan). This
                            // GeometryReader sits UNDER .scaleEffect/.offset, so once zoomed it
                            // reports the SCALED+offset rect and the zoom-toward-cursor centre C
                            // would drift (the cursor slides off the point as you keep scrolling).
                            // At fit the reported frame IS the constant unscaled rect the solver needs.
                            .onAppear { if resultZoom == 1 && resultPan == .zero { resultImageFrame = geo.frame(in: .global) } }
                            .onChange(of: geo.frame(in: .global)) { _, f in
                                // Capture the fitted rect ONLY at fit. Do NOT reset zoom from here:
                                // this reader sits UNDER .scaleEffect, so scrolling to zoom changes
                                // its OWN frame — an else-branch reset here would cancel the zoom on
                                // every scroll step (it killed the feature). The resize-while-zoomed
                                // reset is driven by the OUTER canvas reader, which is above the scale.
                                if resultZoom == 1 && resultPan == .zero { resultImageFrame = f }
                            }
                    })
                    .scaleEffect(resultZoom, anchor: .center)
                    .offset(resultPan)
                    .onDrag { resultDragProvider() }
                    .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.15)) { resultZoom = 1; resultPan = .zero } }
                    .help("Scroll to zoom toward the cursor · double-click to reset. Drag the image out — into Finder, a chat, an editor. The dragged PNG carries the full recipe (prompt, seed, size, LoRA); re-saving as JPEG strips it.")
                resultOverlays
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if vm.isBusy {
            Group {
                if let prev = vm.previewImage {
                    // Live render preview — the image taking shape, crossfading between steps.
                    // Early "Every step" frames are soft-focused so they resolve INTO clarity
                    // instead of flashing raw latent noise (the harsh raw-noise look the user disliked).
                    ZStack {
                        Image(decorative: prev, scale: 1)
                            .resizable().scaledToFit()
                            .blur(radius: previewBlurRadius)
                            .id(vm.previewStep)               // new identity per step → the fade fires
                            .transition(.opacity)
                        VStack {
                            HStack {
                                Spacer()
                                HStack(spacing: 6) {
                                    FxDot(tone: .amber, live: true, size: 6)
                                    Text("preview · step \(vm.previewStep)/\(vm.steps)")
                                }
                                .font(.fxMono(10.5)).foregroundStyle(Color.fxText)
                                .fxChip(padV: 3, padH: 9)
                            }
                            .padding(12)
                            Spacer()
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: vm.previewStep)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(spacing: 14) {
                        ZStack {
                            Ring(pct: vm.progress, size: 76, lineWidth: 6)
                            Text("\(Int(vm.progress * 100))%").font(.fxMono(15, weight: .bold)).foregroundStyle(Color.fxText)
                        }
                        Text("step \(vm.currentStep) / \(vm.steps)").font(.fxMono(12)).foregroundStyle(Color.fxText2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                canvasBottomBar {
                    Text("\(vm.width) × \(vm.height) · denoise")
                    Spacer()
                    if let eta = vm.etaSeconds, eta > 0 { Text(etaHuman(eta)) }
                }
            }
        } else if vm.modelMissing || vm.encoderMissing {
            // First-launch dead-end fix: a fresh install used to show "Your image will
            // appear here" with a Generate button that only produced an error.
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 42)).foregroundStyle(Color.fxAccent.opacity(0.8))
                Text(vm.modelMissing ? "\(vm.tier.shortName) isn't on this Mac yet"
                                     : "\(vm.tier.shortName) is missing its text encoder")
                    .font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText)
                Text(vm.modelMissing
                     ? "Download it once in the Models tab — after that everything runs offline."
                     : "One click on \u{201C}Get encoder\u{201D} in the Models tab fixes it.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button("Open Models") { openModels() }
                    .buttonStyle(FxPrimaryButtonStyle(height: 32))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 42)).foregroundStyle(Color.fxText3.opacity(0.7))
                Text("Your image will appear here").font(.fx(13)).foregroundStyle(Color.fxText3)
                Text("\(vm.width) × \(vm.height) · \(vm.tier.displayName)")
                    .font(.fxMono(11)).foregroundStyle(Color.fxText3.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help("Drop a Typhoonminigen PNG anywhere on the canvas to restore its full recipe — prompt, seed, size, model and LoRA return to the form.")
        }
    }

    private var resultOverlays: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) { FxDot(tone: .ok); Text("done") }
                    .font(.fx(10.5)).foregroundStyle(Color.fxText).fxChip(padV: 3, padH: 9)
                Spacer()
                Button { vm.upscaleResult(scale: 2) } label: {
                    Text("×2").font(.fx(10.5)).foregroundStyle(Color.fxText)
                }
                .buttonStyle(.plain).fxChip(padV: 3, padH: 9)
                .disabled(vm.isUpscaling || vm.lastSavedURL == nil)
                .help("Upscale ×2 with Real-ESRGAN — saves a new PNG next to the original in the Gallery. Generate near 1 MP, then upscale, instead of rendering large.")
                Button { vm.upscaleResult(scale: 4) } label: {
                    Text(vm.isUpscaling ? "…" : "×4").font(.fx(10.5)).foregroundStyle(Color.fxText)
                }
                .buttonStyle(.plain).fxChip(padV: 3, padH: 9)
                .disabled(vm.isUpscaling || vm.lastSavedURL == nil)
                .help("Upscale ×4 with Real-ESRGAN — saves a new PNG next to the original in the Gallery. Generate near 1 MP, then upscale, instead of rendering large.")
                Button { vm.saveResultAs() } label: { Text("save").font(.fx(10.5)).foregroundStyle(Color.fxText) }
                    .buttonStyle(.plain).fxChip(padV: 3, padH: 9)
                    .help("Export a copy to a location you choose (the original is already in the Gallery)")
                Button { vm.pinLastSeed() } label: { Text("pin seed").font(.fx(10.5)).foregroundStyle(Color.fxText) }
                    .buttonStyle(.plain).fxChip(padV: 3, padH: 9)
                    .help("Put this image's seed into the Seed field — follow-up renders iterate on the same composition")
                Button { vm.useResultAsReference() } label: { Text("to I2I").font(.fx(10.5)).foregroundStyle(Color.fxText) }
                    .buttonStyle(.plain).fxChip(padV: 3, padH: 9)
                    .help("Add this result as an I2I reference (max 3). The first reference also snaps the output size to its aspect ratio.")
                Button { vm.clearPreview() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.fxText)
                }
                .buttonStyle(.plain).fxChip(padV: 4, padH: 7)
                .help("Clear the canvas — the image itself stays in the Gallery")
            }
            .padding(12)
            .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
            canvasBottomBar {
                Text("\(vm.width) × \(vm.height) · \(vm.steps) steps")
                Spacer()
                Text(resultMeta)
            }
        }
    }

    private var resultMeta: String {
        var parts: [String] = []
        if let seed = vm.lastSeed { parts.append("seed \(shortSeed(seed))") }
        if let t = vm.lastGenText { parts.append(t) }
        return parts.joined(separator: " · ")
    }

    private func shortSeed(_ seed: UInt64) -> String {
        let s = String(seed)
        guard s.count > 10 else { return s }
        return "\(s.prefix(4))…\(s.suffix(5))"
    }

    private func canvasBottomBar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .font(.fxMono(11)).foregroundStyle(Color.fxText2)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
    }

    // ════════════════════════════ COLUMN 3 — TELEMETRY RAIL ════════════════════════════

    private var rail: some View {
        let s = telemetry.snapshot
        return VStack(spacing: 12) {
            genRailCard
            cpuRailCard(s)
            gpuRailCard(s)
            ramRailCard(s)
            mlxRailCard(s)
            storageRailCard(s)
        }
    }

    private var genProgress: Double { vm.isBusy ? vm.progress : (vm.progress > 0 ? 1 : 0) }

    // Simple and bold (user feedback: the old step/percent/seconds pile read as cluttered):
    // big % inside the ring, one human time line, one small step line. No s/it engineering.
    private var genRailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                FxDot(tone: .amber, live: vm.isBusy)
                Text("GENERATION").font(.fx(11, weight: .semibold)).tracking(0.8).foregroundStyle(Color.fxText3)
            }
            HStack(spacing: 14) {
                ZStack {
                    Ring(pct: genProgress, size: 72, lineWidth: 7)
                    Text("\(Int(genProgress * 100))%")
                        .font(.fxMono(15, weight: .bold)).foregroundStyle(Color.fxText)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(genStateWord)
                        .font(.fx(13, weight: .semibold))
                        .foregroundStyle(vm.isBusy ? Color.fxAccent : Color.fxText2)
                    if vm.isBusy {
                        if let eta = vm.etaSeconds, eta > 0 {
                            Text(etaHuman(eta)).font(.fxMono(11)).foregroundStyle(Color.fxText3)
                        }
                        Text("step \(vm.currentStep) of \(vm.steps)")
                            .font(.fxMono(10.5)).foregroundStyle(Color.fxText3)
                        if vm.queueRunning && vm.queueTotal > 1 {
                            Text("image \(min(vm.queueDone + 1, vm.queueTotal)) of \(vm.queueTotal)")
                                .font(.fxMono(10.5)).foregroundStyle(Color.fxAccent)
                        }
                    } else if let t = vm.lastGenText {
                        Text("in \(t)").font(.fxMono(11)).foregroundStyle(Color.fxText3)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 12)
    }

    private var genStateWord: String {
        if vm.isBusy { return vm.currentStep == 0 ? "warming up" : "rendering" }
        return vm.progress > 0 ? "done" : "idle"
    }

    /// "~40 s left" under 90 s, "~7 min left" above — no raw three-digit second counts.
    private func etaHuman(_ s: Double) -> String {
        if s < 90 { return "~\(Int(s.rounded())) s left" }
        return "~\(Int((s / 60).rounded(.up))) min left"
    }

    // CPU — load % + history sparkline + core count.
    private func cpuRailCard(_ s: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metricHead("cpu", "CPU", "\(Int(s.cpuPercent.rounded()))%", tone: loadTone(s.cpuPercent))
            Sparkline(data: telemetry.cpuHistory, color: .fxAccent).frame(height: 40)
            railFootnote("\(ProcessInfo.processInfo.activeProcessorCount)-core CPU")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 13)
    }

    // GPU — load % + history sparkline + chip name & thermal state.
    private func gpuRailCard(_ s: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metricHead("display", "GPU", "\(Int(s.gpuPercent.rounded()))%", tone: loadTone(s.gpuPercent))
            railFootnote("\(s.gpuName) · \(s.gpuCoreCount > 0 ? "\(s.gpuCoreCount)-core" : "GPU")")
            Sparkline(data: telemetry.gpuHistory, color: .fxAccent).frame(height: 40)
            railStatDot("thermal", thermalLabel(s.thermalState), tone: thermalTone(s.thermalState))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 13)
    }

    // RAM — whole-system memory: % used (big), live load graph, used/total bar.
    private func ramRailCard(_ s: TelemetrySnapshot) -> some View {
        let frac = fraction(Double(s.systemUsedBytes), Double(s.systemTotalBytes))
        return VStack(alignment: .leading, spacing: 10) {
            metricHead("memorychip", "RAM", "\(Int((frac * 100).rounded()))%", tone: ramTone(frac))
            Sparkline(data: telemetry.ramHistory, color: .fxAccent).frame(height: 40)
            Meter(value: frac, ok: frac < 0.8)
            HStack {
                Text("\(ByteFormat.string(s.systemUsedBytes)) used")
                Spacer()
                Text("\(ByteFormat.string(s.systemTotalBytes)) total")
            }
            .font(.fxMono(10.5)).foregroundStyle(Color.fxText3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 13)
    }

    // MLX — Klein's framework memory: active (big), trend, peak/total bar, pressure & swap.
    private func mlxRailCard(_ s: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metricHead("square.stack.3d.up.fill", "MLX MEMORY", ByteFormat.string(s.mlxActiveBytes), tone: .fxOk)
            railFootnote("active — Klein resident in unified memory")
            Sparkline(data: telemetry.mlxHistory, color: .fxOk).frame(height: 40)
            // Bar = session PEAK / total (matches the "peak / total" labels below); the live
            // sparkline above already shows the dynamic active trend.
            Meter(value: fraction(Double(s.mlxPeakBytes), Double(s.systemTotalBytes)), ok: true)
            HStack {
                Text("\(ByteFormat.string(s.mlxPeakBytes)) peak")
                Spacer()
                Text("\(ByteFormat.string(s.systemTotalBytes)) total")
            }
            .font(.fxMono(10.5)).foregroundStyle(Color.fxText3)
            railDivider
            railStatDot("pressure", pressureLabel(s.memoryPressureLevel), tone: pressureTone(s.memoryPressureLevel))
            railStat("swap", ByteFormat.string(s.swapUsedBytes))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 13)
    }

    // Storage — disk: % used (big), used/total bar, free space.
    private func storageRailCard(_ s: TelemetrySnapshot) -> some View {
        let frac = fraction(Double(s.diskTotalBytes - s.diskFreeBytes), Double(s.diskTotalBytes))
        return VStack(alignment: .leading, spacing: 10) {
            metricHead("externaldrive", "STORAGE", "\(Int((frac * 100).rounded()))%")
            Meter(value: frac)
            HStack {
                Text("\(ByteFormat.string(s.diskFreeBytes)) free")
                Spacer()
                Text("\(ByteFormat.string(s.diskTotalBytes)) total")
            }
            .font(.fxMono(10.5)).foregroundStyle(Color.fxText3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 13)
    }

    // rail helpers
    /// Card header: icon + uppercase title (left), big mono value (right).
    private func metricHead(_ icon: String, _ title: String, _ value: String, tone: Color = .fxText) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.fxText3)
            Text(title).font(.fx(11, weight: .semibold)).tracking(0.8).foregroundStyle(Color.fxText3)
            Spacer(minLength: 6)
            Text(value).font(.fxMono(18, weight: .bold)).foregroundStyle(tone)
        }
    }
    private func railFootnote(_ text: String) -> some View {
        Text(text).font(.fxMono(10)).foregroundStyle(Color.fxText3).lineLimit(1)
    }
    private func loadTone(_ pct: Double) -> Color { pct >= 90 ? .fxDanger : (pct >= 70 ? .fxAccent : .fxText) }
    private func ramTone(_ frac: Double) -> Color { frac >= 0.9 ? .fxDanger : (frac >= 0.8 ? .fxAccent : .fxText) }
    private func railStat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.fx(11.5)).foregroundStyle(Color.fxText2)
            Spacer()
            Text(value).font(.fxMono(12)).foregroundStyle(Color.fxText)
        }
    }
    private func railStatDot(_ label: String, _ value: String, tone: FxTone) -> some View {
        HStack {
            Text(label).font(.fx(11.5)).foregroundStyle(Color.fxText2)
            Spacer()
            HStack(spacing: 6) { FxDot(tone: tone); Text(value).font(.fxMono(12)).foregroundStyle(Color.fxText) }
        }
    }
    private var railDivider: some View {
        Rectangle().fill(Color.fxBorder).frame(height: 1).padding(.vertical, 1)
    }
    private func fraction(_ part: Double, _ whole: Double) -> Double {
        whole > 0 ? max(0, min(1, part / whole)) : 0
    }
    private func thermalLabel(_ v: Int) -> String { ["normal", "warm", "hot", "critical"][min(3, max(0, v))] }
    private func thermalTone(_ v: Int) -> FxTone {
        switch v { case ...0: return .ok; case 3: return .danger; default: return .amber }
    }
    private func pressureLabel(_ v: Int) -> String {
        switch v { case 2: return "elevated"; case 4: return "critical"; default: return "normal" }
    }
    private func pressureTone(_ v: Int) -> FxTone {
        switch v { case 4: return .danger; case 2: return .amber; default: return .ok }
    }
}

// ── Reference images (up to 3 slots) / drop zone ─────────────────────────────
private struct ReferenceImageSection: View {
    @Bindable var vm: GenerateViewModel
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "photo.badge.arrow.down").font(.system(size: 13)).foregroundStyle(Color.fxText3)
                Text("References (I2I)").font(.fx(12, weight: .medium)).foregroundStyle(Color.fxText3)
                if vm.isI2IMode {
                    Text(vm.references.count > 1 ? "· I2I ×\(vm.references.count)" : "· I2I")
                        .font(.fx(10.5, weight: .semibold)).foregroundStyle(Color.fxAccent)
                }
                Spacer(minLength: 8)
                if vm.references.count > 1 {
                    Button("Clear") { vm.clearReferences() }
                        .buttonStyle(FxGhostButtonStyle(height: 22, accentText: true))
                        .help("Remove all references and return to text-to-image — the output size you had before adding references is restored.")
                }
            }

            if !vm.references.isEmpty {
                HStack(spacing: 8) {
                    ForEach(vm.references) { slot in
                        slotThumb(slot)
                    }
                    Spacer(minLength: 0)
                }
                if vm.references.count >= 2 {
                    Text("Each reference adds time at 1024²: Klein 9B — 2 refs ≈ 6–7 min, 3 refs ≈ 10 min; Klein 4B — 1 ref ≈ 2.5 min, 3 refs ≈ 7 min.")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button { vm.describeReferences() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "text.viewfinder").font(.system(size: 11))
                            Text(vm.isDescribing ? "Describing…" : "Describe with AI")
                        }
                        .font(.fx(11.5))
                    }
                    .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
                    .disabled(vm.isDescribing || vm.isBusy || vm.queueRunning)
                    .opacity(vm.isDescribing || vm.isBusy || vm.queueRunning ? 0.5 : 1)
                    .help("Qwen3.5 vision model (~3 GB, downloads once) looks at each reference and appends its description to the prompt — it never overwrites your text; edit the result freely.")
                    if vm.isDescribing {
                        // Describe used to be unabortable — a stuck run latched the whole
                        // Generate button until relaunch.
                        Button("Cancel") { vm.cancelDescribe() }
                            .buttonStyle(FxGhostButtonStyle(height: 26))
                            .help("Stops after the current reference; an in-flight download stops immediately")
                    } else {
                        Text("writes what it sees into the prompt")
                            .font(.fx(10.5)).foregroundStyle(Color.fxText3).lineLimit(1)
                    }
                }
            }

            if vm.references.count < GenerateViewModel.maxReferences {
                FxDropZone(isTargeted: isTargeted) {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 20)).foregroundStyle(Color.fxText3.opacity(0.8))
                        (Text(vm.references.isEmpty ? "Drop here or " : "Add another or ").foregroundColor(.fxText3)
                         + Text("choose files…").foregroundColor(.fxAccent))
                            .font(.fx(12))
                        Text("\(vm.references.count)/\(GenerateViewModel.maxReferences)")
                            .font(.fxMono(10)).foregroundStyle(Color.fxText3)
                    }
                }
                // #13 register the WHOLE padded box as the hit area — without this the drop
                // (and the click) only land on the icon/text, so a Finder drag onto the empty
                // part of the box silently does nothing.
                .contentShape(Rectangle())
                .onTapGesture { vm.selectReferenceImages() }
                .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isTargeted) { providers in
                    let free = GenerateViewModel.maxReferences - vm.references.count
                    guard free > 0, !providers.isEmpty else { return false }
                    for (i, provider) in providers.prefix(free).enumerated() {
                        // #13 Prefer the image-DATA representation. A Finder/Desktop image file
                        // exposes BOTH a file URL and its image bytes, and loading the bytes is
                        // reliable — whereas loadObject(URL:) intermittently yields nil for Finder
                        // drags on some macOS builds, which silently dropped the drop (the bug).
                        // Photos / a browser also vend image data. Fall back to the file URL only
                        // when the provider exposes no image representation at all.
                        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                                // On-disk file (Finder/Desktop): decode from the reliable image
                                // DATA (loadObject(URL:) is flaky for Finder drags — the #13 bug),
                                // but ALSO keep the file URL so the saved recipe records this
                                // reference (buildRequest reads slot.url?.path). A nil URL falls
                                // back to the data-only behavior — no regression vs before. The
                                // box captures the (thread-safe but non-Sendable) provider into the
                                // outer @Sendable completion so the nested data load is warning-free.
                                let box = SendableProvider(provider)
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                    _ = box.provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                                        DispatchQueue.main.async {
                                            if let data {
                                                vm.addReference(fromImageData: data, url: url, snapToFirst: i == 0)
                                            } else if let url {
                                                // Image bytes unavailable (corrupt/odd file): retry by
                                                // URL, which reports an honest "Couldn't read…" if it
                                                // also fails — no silent drop.
                                                vm.addReference(from: url, snapToFirst: i == 0)
                                            }
                                        }
                                    }
                                }
                            } else {
                                // Photos / browser drag — image bytes, no file on disk.
                                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                                    DispatchQueue.main.async {
                                        if let data { vm.addReference(fromImageData: data, snapToFirst: i == 0) }
                                        else { vm.statusMessage = "Couldn't read the dropped image." }
                                    }
                                }
                            }
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                guard let url else { return }
                                DispatchQueue.main.async { vm.addReference(from: url, snapToFirst: i == 0) }
                            }
                        }
                    }
                    return true
                }
                .help("Drop up to 3 images here, or click to choose files. The first reference sets the output size to its aspect; the engine downscales references to a ≤1024² area. Each extra reference adds minutes of render time.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 12)
    }

    private func slotThumb(_ slot: GenerateViewModel.ReferenceSlot) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(decorative: slot.image, scale: 1)
                .resizable().scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
            Button { vm.removeReference(slot.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.fxText)
                    .frame(width: 16, height: 16)
                    .background(Color.black.opacity(0.65), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(3)
            .help("Remove this reference")
        }
        .help(slot.url?.lastPathComponent ?? "generated result")
    }
}
