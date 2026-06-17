import SwiftUI
import Observation
import AppKit

@MainActor
@Observable
final class LoRAViewModel {
    var items: [LoRAItem] = []
    var lastAction: ActionMessage? = nil

    private let store: LoRAStore
    private var reloadTask: Task<Void, Never>?
    init(store: LoRAStore) { self.store = store }

    func reload() {
        // Cancel a prior reload so an older discover() snapshot can't land after a newer one
        // (reload fires on appear and can overlap an import/delete). [weak self] = no retain cycle.
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.store.discover()
            guard !Task.isCancelled else { return }
            self.items = items
        }
    }

    func importLoRA() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a .safetensors LoRA file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLoRA(from: url)
    }

    /// Import from a concrete URL — used by both the file picker and drag-and-drop.
    func importLoRA(from url: URL) {
        guard url.pathExtension.lowercased() == "safetensors" else {
            lastAction = .error("A .safetensors file is required")
            return
        }
        Task { @MainActor in
            do {
                let item = try await store.importLoRA(from: url)
                lastAction = item.isCompatible
                    ? .ok("Imported: \(item.fileName) — \(item.note)")
                    : .error("Imported, but \(item.note)")
                AppLog.info("LoRA imported: \(item.fileName) (\(item.note))")
            } catch {
                lastAction = .error("Import error: \(error.localizedDescription)")
            }
            reload()   // refresh via the single cancellable slot so an older discover() snapshot can't land late
        }
    }

    func delete(_ item: LoRAItem) {
        Task { @MainActor in
            do {
                try await store.delete(item)
                lastAction = .ok("Deleted: \(item.fileName)")
                AppLog.info("LoRA deleted: \(item.fileName)")
            } catch {
                lastAction = .error("Couldn't delete \(item.fileName): \(error.localizedDescription)")
                AppLog.error("LoRA delete failed: \(error.localizedDescription)")
            }
            reload()   // refresh via the single cancellable slot so an older discover() snapshot can't land late
        }
    }

    func setTrigger(_ trigger: String, for item: LoRAItem) {
        Task { @MainActor in
            let cleared = trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let ok = await store.setTrigger(trigger, forFileName: item.fileName)
            reload()   // refresh via the single cancellable slot so an older discover() snapshot can't land late
            if ok {
                lastAction = .ok(cleared ? "Trigger cleared for \(item.fileName)"
                                         : "Trigger saved for \(item.fileName)")
            } else {
                lastAction = .error("Couldn't save the trigger for \(item.fileName) — please try again.")
            }
        }
    }
}
