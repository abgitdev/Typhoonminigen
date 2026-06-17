import Foundation
import Observation

/// One user-defined prompt chip (persisted; built-ins live in `PromptPresets`).
struct CustomPreset: Codable, Identifiable, Sendable {
    let id: String          // "custom.<uuid>" — the prefix marks deletable chips in the UI
    let phrase: String
    let category: String    // PromptPresetCategory.rawValue
}

/// Owns the user's own preset chips: add / remove / persist to custom-presets.json.
@MainActor
@Observable
final class CustomPresetStore {
    static let shared = CustomPresetStore()

    private(set) var items: [CustomPreset] = []
    /// Built-in chips the user chose to hide (id set; built-ins live in code, so "delete" = hide).
    private(set) var hiddenIDs: Set<String> = []
    private var fileURL: URL { AppPaths.appSupport.appendingPathComponent("custom-presets.json") }
    private static let hiddenKey = "hiddenPresetIDs"

    init() {
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            if let list = try? JSONDecoder().decode([CustomPreset].self, from: data) {
                items = list
            } else {
                // Don't silently wipe the user's chips: keep the unreadable file as a backup
                // so the next save() can't overwrite it into oblivion.
                let backup = fileURL.deletingLastPathComponent().appendingPathComponent("custom-presets.corrupt.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: fileURL, to: backup)
                AppLog.error("custom-presets.json unreadable — kept a backup as custom-presets.corrupt.json")
            }
        }
        hiddenIDs = Set(UserDefaults.standard.array(forKey: Self.hiddenKey) as? [String] ?? [])
    }

    func hide(_ id: String) {
        hiddenIDs.insert(id)
        UserDefaults.standard.set(Array(hiddenIDs), forKey: Self.hiddenKey)
    }

    func unhideAll(in category: PromptPresetCategory) {
        hiddenIDs.subtract(PromptPresets.presets(for: category).map(\.id))
        UserDefaults.standard.set(Array(hiddenIDs), forKey: Self.hiddenKey)
    }

    /// Un-hide a specific chip set — applying a LOOK bundle restores its hidden chips
    /// (a hidden id is filtered out of the prompt assembly, so it must come back).
    func unhide(_ ids: some Sequence<String>) {
        hiddenIDs.subtract(ids)
        UserDefaults.standard.set(Array(hiddenIDs), forKey: Self.hiddenKey)
    }

    func hiddenCount(in category: PromptPresetCategory) -> Int {
        PromptPresets.presets(for: category).filter { hiddenIDs.contains($0.id) }.count
    }

    /// Drop all in-memory custom chips + hidden-chip state. Called by "Remove all data" so the live
    /// UI can't keep showing — or re-saving — chips whose backing JSON + UserDefaults were just
    /// wiped. Deliberately does NOT re-persist: the wipe already cleared both backing stores.
    func reset() {
        items = []
        hiddenIDs = []
    }

    @discardableResult
    private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        do { try data.write(to: fileURL, options: .atomic); return true }
        catch { return false }
    }

    /// User chips of one category, as regular chips (label = trimmed phrase excerpt).
    func chips(for category: PromptPresetCategory) -> [PromptPreset] {
        items.filter { $0.category == category.rawValue }.map {
            let label = $0.phrase.count > 24 ? String($0.phrase.prefix(22)) + "…" : $0.phrase
            return PromptPreset(id: $0.id, label: label, phrase: $0.phrase)
        }
    }

    func category(for id: String) -> PromptPresetCategory? {
        items.first { $0.id == id }.flatMap { PromptPresetCategory(rawValue: $0.category) }
    }

    func add(phrase: String, to category: PromptPresetCategory) {
        let t = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(CustomPreset(id: "custom.\(UUID().uuidString)", phrase: t, category: category.rawValue))
        if persist() {
            AppLog.info("Custom preset added (\(category.rawValue)): \(t.prefix(40))")
        } else {
            // Don't claim success the relaunch will silently contradict — the chip works this
            // session but won't survive a restart.
            AppLog.error("Custom preset NOT saved (write failed) — it will be lost on relaunch: \(t.prefix(40))")
        }
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        if !persist() { AppLog.error("Custom preset removal not persisted — it may reappear on relaunch") }
    }
}

/// Single lookup surface over BUILT-IN + CUSTOM chips — the UI and the prompt assembly go
/// through this so user chips behave exactly like built-ins (selection, single/multi rules,
/// BFL append order).
@MainActor
enum PresetCatalog {
    static func presets(for category: PromptPresetCategory) -> [PromptPreset] {
        PromptPresets.presets(for: category)
            .filter { !CustomPresetStore.shared.hiddenIDs.contains($0.id) }
            + CustomPresetStore.shared.chips(for: category)
    }

    static func category(for id: String) -> PromptPresetCategory? {
        PromptPresets.category(for: id) ?? CustomPresetStore.shared.category(for: id)
    }

    /// `ignoringHidden`: include chips the user hid in the Generate card too. Used by the Library
    /// queue path so a scene's chips apply even if hidden, WITHOUT permanently un-hiding them
    /// (a queue-add must not mutate global UI state). The live-form path keeps hidden filtered.
    static func suffix(for selected: Set<String>, ignoringHidden: Bool = false) -> String {
        guard !selected.isEmpty else { return "" }
        var phrases: [String] = []
        for category in PromptPresetCategory.appendOrder {
            let pool = ignoringHidden
                ? PromptPresets.presets(for: category) + CustomPresetStore.shared.chips(for: category)
                : presets(for: category)
            for preset in pool where selected.contains(preset.id) {
                phrases.append(preset.phrase)
            }
        }
        return phrases.joined(separator: ", ")
    }
}
