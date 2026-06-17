import SwiftUI
import Observation
import AppKit

@MainActor
@Observable
final class SystemViewModel {
    let telemetry: TelemetryService     // shared, app-lifetime (status bar + rail also read it)
    var logLines: [String] = []
    var lastAction: ActionMessage? = nil

    private let engine: FluxEngine
    private let store: GenerationStore   // wiped by removeAllData so the gallery keeps no "missing" ghosts
    // C-5: injected by TyphoonminigenApp so clearCaches() can guard against mid-gen calls
    @ObservationIgnored var isBusyProvider: (() -> Bool)?
    /// Fired after freeMemory() so the header model chip re-syncs immediately.
    @ObservationIgnored var onModelStateChange: (() -> Void)? = nil
    /// Fired after removeAllData() clears the gallery store so the Gallery view refreshes to empty.
    @ObservationIgnored var onDataRemoved: (() -> Void)? = nil

    init(engine: FluxEngine, telemetry: TelemetryService, store: GenerationStore) {
        self.engine = engine
        self.telemetry = telemetry
        self.store = store
    }

    func onAppear() {
        telemetry.start()   // idempotent; the shared sampler is already running
        refreshLogs()
    }

    /// Telemetry intentionally keeps sampling after leaving the System screen — the bottom
    /// status bar and the Generation rail rely on it everywhere.
    func onDisappear() {}

    func refreshLogs() {
        logLines = Array(AppLog.shared.recent().suffix(200).reversed())
    }

    func clearLogs() {
        let result = MaintenanceService.clearLogs()
        refreshLogs()
        if result.remaining == 0 {
            lastAction = .ok("Logs cleared — freed \(ByteFormat.string(result.freed)) (0 bytes left).")
        } else {
            // These logs hold seeds / file names / LoRA names — don't claim erasure that didn't happen.
            lastAction = .error("Logs only partially cleared — \(ByteFormat.string(result.remaining)) still on disk. Try again.")
        }
    }

    func clearCaches() {
        // C-5: clearing the MLX buffer pool during generation can corrupt in-flight GPU buffers
        if isBusyProvider?() == true {
            lastAction = .error("Busy — a render, describe, download, import or upscale is running. Try again when it finishes.")
            return
        }
        lastAction = .ok("Clearing cache…")
        Task { @MainActor in
            // Walk + delete the caches tree OFF the main actor so the window doesn't beachball.
            let freed = await Task.detached(priority: .userInitiated) { MaintenanceService.clearCaches() }.value
            // Re-gate the GPU-pool flush: the FS walk ran off-actor, so a generation could have begun
            // in the gap. Only flush if still idle (closes the TOCTOU window that v0.63 opened).
            if isBusyProvider?() != true { MaintenanceService.clearMLXPool() }
            lastAction = .ok(freed > 0
                ? "Cache cleared — freed \(ByteFormat.string(freed))."
                : "Cache already empty — 0 bytes.")
            AppLog.info("Cache cleared: \(ByteFormat.string(freed))")
            refreshLogs()
        }
    }

    func freeMemory() {
        Task { @MainActor in
            let freed = await engine.freeMemory()
            if freed {
                AppLog.info("Model unloaded from memory (System)")
                lastAction = .ok("Model unloaded from memory.")
            } else {
                lastAction = .error("The model is in use (a render or describe is running) — try again when it finishes.")
            }
            refreshLogs()
            onModelStateChange?()
        }
    }

    /// Delete EVERYTHING the app stored (System "Remove all data…") — for use right before
    /// trashing the .app. Unloads any resident model first, then wipes all data + the HF cache.
    func removeAllData() {
        if isBusyProvider?() == true {
            lastAction = .error("Busy — a render, describe, download, import or upscale is running. Try again when it finishes.")
            return
        }
        Task { @MainActor in
            _ = await engine.freeMemory()   // unload any resident model so nothing is mid-read
            // Walk + delete the multi-GB Models/HF-cache tree OFF the main actor (it used to
            // beachball the window for seconds-to-minutes).
            let freed = await Task.detached(priority: .userInitiated) { MaintenanceService.removeAllData() }.value
            // Disk is wiped; now clear the in-memory gallery + rewrite a clean empty index so the
            // Gallery shows 0 (not N "missing" ghosts) and a later save can still persist.
            await store.reset()
            // Also drop the in-memory custom-preset state (its JSON + UserDefaults were just wiped)
            // so the live UI can't keep showing — or re-persisting — chips that no longer exist.
            CustomPresetStore.shared.reset()
            onDataRemoved?()
            AppLog.info("Removed ALL app data — freed \(ByteFormat.string(freed))")
            lastAction = .ok("Removed all models & data — freed \(ByteFormat.string(freed)). Quitting now so nothing is left behind — then drag the app to the Trash.")
            onModelStateChange?()
            refreshLogs()
            // Quit after a moment (so the message is readable): any in-memory @AppStorage value would
            // otherwise re-write the just-cleared settings domain on the next interaction, leaving
            // stale flags behind — contradicting "nothing is left behind".
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { NSApplication.shared.terminate(nil) }
        }
    }
}
