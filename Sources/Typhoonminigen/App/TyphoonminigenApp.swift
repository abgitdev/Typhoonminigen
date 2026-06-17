import SwiftUI
import AppKit
import Flux2Core
import FluxTextEncoders

@main
struct TyphoonminigenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var generateVM: GenerateViewModel
    @State private var galleryVM: GalleryViewModel
    @State private var modelsVM: ModelsViewModel
    @State private var loraVM: LoRAViewModel
    @State private var systemVM: SystemViewModel

    @State private var telemetry: TelemetryService
    @State private var sessionStats: SessionStats

    init() {
        let engine = FluxEngine()
        let store = GenerationStore()       // shared: Generate saves into it, Gallery reads it
        let loraStore = LoRAStore()         // shared: LoRA tab manages, Generate picks
        let telemetry = TelemetryService()  // shared: status bar + rail + System screen
        let stats = SessionStats()
        let gvm = GenerateViewModel(engine: engine, store: store, loraStore: loraStore, sessionStats: stats)
        let svm = SystemViewModel(engine: engine, telemetry: telemetry, store: store)
        let mvm = ModelsViewModel(engine: engine)
        // C-5: SystemViewModel needs to know if a generation OR a VLM describe is in flight
        // before clearing the MLX cache (both hold the global pool).
        // Also block while a model download/import is in flight: removeAllData/clearCaches delete
        // the Models tree the downloader is still writing into (the quit-guard already checks these).
        svm.isBusyProvider = { [weak gvm, weak mvm] in
            (gvm?.isBusy ?? false) || (gvm?.isDescribing ?? false)
            || (mvm?.downloadingTier != nil) || (mvm?.importing ?? false)
            || UpscaleService.isBusy
        }
        // The header model chip reads GenerateViewModel — re-sync it the moment the
        // Models/System tabs unload, download, or delete a model.
        let syncChip: () -> Void = { [weak gvm] in Task { @MainActor in await gvm?.syncModelState() } }
        mvm.onModelStateChange = syncChip
        svm.onModelStateChange = syncChip
        // Created early so System's "Remove all data" can refresh it to empty after wiping the store.
        let gallery = GalleryViewModel(store: store)
        svm.onDataRemoved = { [weak gallery] in gallery?.reload() }
        _generateVM = State(initialValue: gvm)
        _galleryVM = State(initialValue: gallery)
        _modelsVM = State(initialValue: mvm)
        _loraVM = State(initialValue: LoRAViewModel(store: loraStore))
        _systemVM = State(initialValue: svm)
        _telemetry = State(initialValue: telemetry)
        _sessionStats = State(initialValue: stats)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(generateVM: generateVM, galleryVM: galleryVM,
                        modelsVM: modelsVM, loraVM: loraVM, systemVM: systemVM,
                        telemetry: telemetry, sessionStats: sessionStats)
                // 1200 so the Generate screen's three columns (sidebar + 360 controls + ~300
                // canvas + 250 rail + gaps/padding ≈ 1194) never overflow at the minimum width.
                .frame(minWidth: 1200, minHeight: 720)
                .preferredColorScheme(.dark)
                .background(Color.fxBg)
                .task { wireQuitGuard() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // Single-window app: ⌘N opened a second window that re-ran the onboarding gating
            // (duplicate Tutorial/What's-new sheets, last-writer-wins consent). Remove it.
            CommandGroup(replacing: .newItem) {}
            // The macOS menu-bar Help searched for a Help Book this app doesn't ship, so
            // "Typhoonminigen Help" opened a modal "Help isn't available" error. Drop the
            // system item — in-app help lives on the Help tab instead.
            CommandGroup(replacing: .help) {}
        }
    }

    /// Quit-confirmation: name the work Cmd-Q would kill (it used to drop everything
    /// silently). Wired through the adaptor's instance — `NSApp.delegate` is SwiftUI's
    /// own wrapper under @NSApplicationDelegateAdaptor, so casting it to AppDelegate
    /// returns nil and the guard would be dead code.
    private func wireQuitGuard() {
        appDelegate.busyWorkDescription = { [generateVM, modelsVM] in
            if generateVM.queueRunning || generateVM.isBusy {
                let pending = generateVM.queue.count
                return pending > 1
                    ? "A render queue is running (\(pending) items) — the work in progress will be lost."
                    : "A render is in progress — the image being made will be lost."
            }
            if let tier = modelsVM.downloadingTier {
                return "The \(tier.shortName) download is running — it stops if you quit (finished files are kept and reused)."
            }
            if modelsVM.importing {
                return "A weights import is in progress — quitting now can leave a half-imported model."
            }
            // Covers BOTH upscale entry points (canvas and gallery detail) — the child
            // process is global to the app.
            if UpscaleService.isBusy { return "An upscale is running — it will be terminated." }
            if generateVM.isDescribing { return "The AI is describing your references — the result will be lost." }
            return nil
        }
        appDelegate.installCloseGuard()
    }
}

/// Handles launch-time setup that needs AppKit / the engine.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wired from ContentView: returns a human description of work that would be lost by
    /// quitting now (render in flight / queue / download / upscale), or nil when idle.
    var busyWorkDescription: (@MainActor () -> String?)? = nil

    /// Set just before WE trigger termination from the close-button guard, so we don't prompt twice.
    private var bypassQuitConfirm = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if bypassQuitConfirm { return .terminateNow }
        guard let describe = busyWorkDescription, let work = describe() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Typhoonminigen?"
        alert.informativeText = work
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Keep Working")   // was "Cancel" — users read that as "cancel the render"
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Re-route the red close button so a click with work in progress confirms BEFORE the window
    /// closes. The default order closes the window first, then asks — so "Keep Working" left the
    /// app running with no visible window (it looked like it quit). Intercepting the button keeps
    /// the window open when the user declines.
    @MainActor func installCloseGuard() {
        guard let window = NSApp.windows.first(where: { $0.standardWindowButton(.closeButton) != nil }),
              let closeButton = window.standardWindowButton(.closeButton) else { return }
        closeButton.target = self
        closeButton.action = #selector(handleCloseButton(_:))
    }

    @objc @MainActor private func handleCloseButton(_ sender: NSButton) {
        guard let describe = busyWorkDescription, let work = describe() else {
            NSApp.terminate(nil)   // idle: the X quits, same as before
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close Typhoonminigen?"
        alert.informativeText = work
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Keep Working")
        if alert.runModal() == .alertFirstButtonReturn {
            bypassQuitConfirm = true
            NSApp.terminate(nil)
        }
        // "Keep Working" → do nothing: the window stays open and the render keeps going.
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched from a SwiftPM executable, force a proper foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Create all storage directories.
        AppPaths.bootstrap()

        // Redirect the engine's model cache to our app folder — identical wiring to the
        // flux2 CLI (Flux2CLI.swift:15-17) — so we reuse already-downloaded weights and
        // download new ones into the right place. MUST run before any model check.
        ModelRegistry.customModelsDirectory = AppPaths.models
        TextEncoderModelDownloader.customModelsDirectory = AppPaths.models
        TextEncoderModelDownloader.reconfigureHubApi()

        // Queue-finished banners should show even when the app is frontmost.
        QueueNotifier.installDelegate()

        // Aborted multi-GB model downloads strand CFNetworkDownload_*.tmp files in the
        // container temp dir (no resume support in the engine) — reclaim them at launch,
        // when no download can possibly be running.
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: fm.temporaryDirectory, includingPropertiesForKeys: [.fileSizeKey]
            ) else { return }
            var freed: Int64 = 0
            for f in files where f.lastPathComponent.hasPrefix("CFNetworkDownload") {
                let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                do {
                    try fm.removeItem(at: f)
                    freed += size
                } catch { /* in use or gone — leave it */ }
            }
            if freed > 0 { AppLog.info("Removed stale download temps: \(ByteFormat.string(freed))") }
        }

        AppLog.info("Typhoonminigen launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't orphan a GPU-heavy realesrgan child to launchd if the user quits mid-upscale.
        UpscaleService.terminateCurrent()
        // Drag promises are useless after exit; left in place, the pasteboard server tries to
        // materialize them during teardown (and logs the file's path if the image was deleted).
        NSPasteboard(name: .drag).clearContents()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
