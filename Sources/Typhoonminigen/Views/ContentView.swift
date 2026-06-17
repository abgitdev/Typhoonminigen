import SwiftUI
import AppKit

/// App sections shown in the sidebar.
enum AppSection: String, CaseIterable, Identifiable {
    case generate
    case library
    case queue
    case gallery
    case models
    case lora
    case system
    case help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .generate: return "Generate"
        case .library:  return "Library"
        case .queue:    return "Queue"
        case .gallery:  return "Gallery"
        case .models:   return "Models"
        case .lora:     return "LoRA"
        case .system:   return "System"
        case .help:     return "Help"
        }
    }

    var icon: String {
        switch self {
        case .generate: return "wand.and.stars"
        case .library:  return "books.vertical"
        case .queue:    return "list.bullet.rectangle"
        case .gallery:  return "photo.on.rectangle.angled"
        case .models:   return "cube"
        case .lora:     return "point.3.connected.trianglepath.dotted"
        case .system:   return "gauge.with.dots.needle.bottom.50percent"
        case .help:     return "questionmark.circle"
        }
    }

    /// Sidebar tooltip — one sentence per section.
    var help: String {
        switch self {
        case .generate: return "Create images from a prompt, references and LoRA adapters"
        case .library:  return "Browse studios and ready-made scenes — one tap loads a look into Generate"
        case .queue:    return "Line up a batch of different prompts and run them one after another"
        case .gallery:  return "Browse, remix and drag out earlier renders"
        case .models:   return "Download or import the Klein models"
        case .lora:     return "Import and manage LoRA adapters"
        case .system:   return "Telemetry, maintenance and logs"
        case .help:     return "Cheat sheet for every feature — and the welcome tour"
        }
    }
}

/// Root window: custom titlebar + sidebar + detail + bottom telemetry status bar.
struct ContentView: View {
    @Bindable var generateVM: GenerateViewModel
    @Bindable var galleryVM: GalleryViewModel
    @Bindable var modelsVM: ModelsViewModel
    @Bindable var loraVM: LoRAViewModel
    @Bindable var systemVM: SystemViewModel
    @Bindable var telemetry: TelemetryService
    @Bindable var sessionStats: SessionStats

    @State private var section: AppSection = .generate
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("railVisible") private var railVisible = true   // Generate telemetry column — OPEN on a fresh first launch so the app shows in full; the user can hide it from the title bar and that choice persists
    @State private var showTutorial = false
    @State private var showWhatsNew = false
    @State private var whatsNewSince = "0"   // captured BEFORE marking the version seen
    @State private var updateAvailable: UpdateService.UpdateInfo?

    var body: some View {
        VStack(spacing: 0) {
            FxTitleBar(section: section.title, sidebarVisible: $sidebarVisible) {
                titleBarTrailing
            }

            HStack(spacing: 0) {
                if sidebarVisible {
                    FxSidebar(section: $section, tail: sidebarTail)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.fxBg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FxStatusBar(version: AppVersion.current) { statusTrailing }
        }
        .background(Color.fxBg)
        .task {
            telemetry.start()
            galleryVM.reload()
            loraVM.reload()
            if !UserDefaults.standard.bool(forKey: "hasSeenTutorial") {
                showTutorial = true
                // Fresh install: the tour already covers everything — nothing is "new".
                UserDefaults.standard.set(AppVersion.current, forKey: "lastSeenWhatsNewVersion")
            } else if UserDefaults.standard.string(forKey: "lastSeenWhatsNewVersion") != AppVersion.current {
                whatsNewSince = UserDefaults.standard.string(forKey: "lastSeenWhatsNewVersion") ?? "0"
                showWhatsNew = true
                // Mark seen as soon as it's SHOWN — a Cmd-Q before dismissing the sheet used to
                // leave lastSeen stale and re-show "What's new" on every launch.
                UserDefaults.standard.set(AppVersion.current, forKey: "lastSeenWhatsNewVersion")
            }
            if let info = await UpdateService.checkIfDue() {
                updateAvailable = info
            }
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(since: whatsNewSince, onClose: { showWhatsNew = false })
        }
        .sheet(isPresented: $showTutorial, onDismiss: {
            UserDefaults.standard.set(true, forKey: "hasSeenTutorial")
            // The tutorial checkbox may have just opted in to update checks; the
            // service's own guards make this a no-op when it didn't.
            Task {
                if let info = await UpdateService.checkIfDue() {
                    updateAvailable = info
                }
            }
        }) {
            TutorialView(onClose: { showTutorial = false })
        }
        .onChange(of: generateVM.lastSavedURL) { _, _ in galleryVM.reload() }
        // The queue path toggles lastSavedURL nil→URL→nil within one MainActor run, so the
        // canvas-only signal above never fires per queued image; a monotonic counter does (#live-refresh).
        .onChange(of: generateVM.savedImageCount) { _, _ in galleryVM.reload() }
        // The header chip is the app's only chrome-level model indicator — re-sync it
        // from the engine on tab switches so Models/System unloads can't leave it stale.
        .onChange(of: section) { _, _ in Task { await generateVM.syncModelState() } }
    }

    // ── Header right group: update pill + live progress + model chip + rail toggle ──
    @ViewBuilder private var titleBarTrailing: some View {
        if let update = updateAvailable {
            FxUpdatePill(version: update.version) {
                NSWorkspace.shared.open(update.url)
            }
            .contextMenu {
                Button("Skip this version") {
                    UpdateService.dismiss(version: update.version)
                    updateAvailable = nil
                }
            }
        }
        if generateVM.isBusy {
            HStack(spacing: 6) {
                FxDot(tone: .amber, live: true, size: 7)
                Text(busyLine).font(.fxMono(11)).foregroundStyle(Color.fxHdrMuted)
            }
            .padding(.trailing, 4)
            .help("Live render progress — the time left is an estimate based on completed steps.")
        }
        FxModelChip(name: generateVM.tier.shortName, state: modelStateWord)
            .help("Selected model and where it lives right now: in memory (ready), on disk (loads on first render), or not downloaded")
        // The telemetry rail lives only on the Generate screen — so show its toggle ONLY there.
        // (Before, the button appeared on every tab but did nothing off Generate — the bug.)
        if section == .generate {
            FxPanelToggle(icon: "sidebar.right", active: railVisible, help: "Show or hide the telemetry side panel.") {
                withAnimation(.easeInOut(duration: 0.18)) { railVisible.toggle() }
            }
        }
    }

    private var modelStateWord: String {
        if generateVM.isModelLoaded { return "in memory" }
        return generateVM.isModelDownloaded ? "on disk" : "not downloaded"
    }

    private var busyLine: String {
        let pct = Int((generateVM.progress * 100).rounded())
        if let eta = generateVM.etaSeconds, eta > 1 {
            let m = Int(eta / 60)
            return m >= 1 ? "rendering · \(pct)% · ~\(m + 1) min left"
                          : "rendering · \(pct)% · \(Int(eta))s left"
        }
        return generateVM.progress > 0 ? "rendering · \(pct)%" : "warming up…"
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .generate: GenerateView(vm: generateVM, telemetry: telemetry, railVisible: railVisible,
                                     openModels: { section = .models },
                                     openQueue: { section = .queue })
        case .library:  LibraryView(vm: generateVM, goToGenerate: { section = .generate },
                                    openQueue: { section = .queue })
        case .queue:    QueueView(vm: generateVM, goToGenerate: { section = .generate })
        case .gallery:  GalleryView(vm: galleryVM, onRemix: { gen in
                            Task { await generateVM.applyRecipe(gen) }
                            section = .generate
                        })
        case .models:   ModelsView(vm: modelsVM)
        case .lora:     LoRAView(vm: loraVM)
        case .system:   SystemView(vm: systemVM, stats: sessionStats)
        case .help:     HelpView(onShowTutorial: { showTutorial = true },
                                 onShowWhatsNew: { whatsNewSince = AppVersion.current; showWhatsNew = true })   // show only the current release, not the whole changelog
        }
    }

    // ── Sidebar trailing accessories ──────────────────────────────────────────
    private func sidebarTail(_ s: AppSection) -> AnyView? {
        switch s {
        case .generate:
            // Activity indicator only — an idle static dot carried no information.
            return generateVM.isBusy ? AnyView(FxDot(tone: .amber, live: true)) : nil
        case .queue:
            let n = generateVM.queue.count
            return n > 0 ? AnyView(tailText("\(n)")) : nil
        case .gallery:
            let n = galleryVM.generations.count
            return n > 0 ? AnyView(tailText("\(n)")) : nil
        case .system:
            return AnyView(tailText("\(Int(telemetry.snapshot.cpuPercent.rounded()))%"))
        default:
            return nil
        }
    }
    private func tailText(_ t: String) -> some View {
        Text(t).font(.fxMono(10)).foregroundStyle(Color.fxText3)
    }

    // ── Bottom status bar telemetry (same on every view) ──────────────────────
    @ViewBuilder private var statusTrailing: some View {
        let s = telemetry.snapshot
        FxStat(label: "CPU", value: "\(Int(s.cpuPercent.rounded()))%")
            .help("Live CPU load.")
        FxStat(label: "GPU", value: "\(Int(s.gpuPercent.rounded()))%")
            .help("Live GPU utilization.")
        FxStat(label: "RAM", value: ramPair(s))
            .help("Memory in use across the whole Mac / total installed — not just this app.")
        FxStat(label: "MLX", value: ByteFormat.string(s.mlxActiveBytes), accent: true)
            .help("GPU memory currently held by the MLX engine (model weights + working buffers).")
    }

    /// "9.3 / 32 GB" — drops the used-side unit when both sides share it.
    private func ramPair(_ s: TelemetrySnapshot) -> String {
        let used = ByteFormat.string(s.systemUsedBytes)
        let total = ByteFormat.string(s.systemTotalBytes)
        if let unit = total.split(separator: " ").last, used.hasSuffix(" \(unit)") {
            return "\(used.dropLast(unit.count + 1)) / \(total)"
        }
        return "\(used) / \(total)"
    }
}
