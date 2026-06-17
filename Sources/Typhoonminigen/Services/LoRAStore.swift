import Foundation

/// Owns the LoRA folder: discover, import (copy in), delete, and per-LoRA trigger words
/// (stored in a small `.triggers.json` so the user never has to remember them).
actor LoRAStore {
    private var triggersURL: URL { AppPaths.loras.appendingPathComponent(".triggers.json") }

    private func loadTriggers() -> [String: String] {
        guard let data = try? Data(contentsOf: triggersURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    @discardableResult
    private func saveTriggers(_ dict: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        do { try data.write(to: triggersURL, options: .atomic); return true }
        catch { return false }
    }

    func discover() -> [LoRAItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: AppPaths.loras, includingPropertiesForKeys: nil) else {
            return []
        }
        let files = urls.filter {
            $0.pathExtension.lowercased() == "safetensors" && !$0.lastPathComponent.hasPrefix(".")
        }
        // Self-heal the sidecar: drop trigger entries whose .safetensors was deleted outside
        // the app (in-app delete already prunes; Finder deletes used to leave keys forever).
        var stored = loadTriggers()
        let names = Set(files.map(\.lastPathComponent))
        let stale = stored.keys.filter { !names.contains($0) }
        if !stale.isEmpty {
            for key in stale { stored.removeValue(forKey: key) }
            saveTriggers(stored)
        }
        return files
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { item(for: $0, stored: stored) }
    }

    /// Case-insensitive lookup of an already-imported file (APFS is case-insensitive by
    /// default). Returns the URL with the ON-DISK casing so we never rename it on re-import.
    private func existingFile(named name: String) -> URL? {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: AppPaths.loras, includingPropertiesForKeys: nil) else { return nil }
        return urls.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }

    func importLoRA(from src: URL) throws -> LoRAItem {
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.loras, withIntermediateDirectories: true)
        // Reuse the existing on-disk filename (and its exact casing) when re-importing a
        // same-named file, so case-sensitive recipe / PNG-recipe name matches don't orphan
        // (re-importing "style.safetensors" over "Style.safetensors" must NOT rename it).
        let existing = existingFile(named: src.lastPathComponent)
        let dest = existing ?? AppPaths.loras.appendingPathComponent(src.lastPathComponent)

        // Self-import: the user picked a file ALREADY inside the LoRAs folder (open panel or
        // drag). The old remove-then-copy deleted the source, then copyItem threw 'no such
        // file' — the adapter was gone forever (no Trash). Just return it untouched.
        // Case-insensitive: APFS is case-insensitive and `dest` carries the on-disk casing, so a
        // differently-cased re-import of the same file (Style vs style) is still a self-import —
        // a case-sensitive compare would treat it as a replace and wipe the trigger word below.
        if src.standardizedFileURL.path.caseInsensitiveCompare(dest.standardizedFileURL.path) == .orderedSame {
            return item(for: dest, stored: loadTriggers())
        }

        let replacing = existing != nil

        // Copy to a temp name first, then atomically swap it in. A failed copy (ejected drive,
        // permission error) can no longer destroy the adapter that was already at `dest`.
        let tmp = AppPaths.loras.appendingPathComponent(".import-\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: src, to: tmp)
            if replacing {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
                // Prune the old trigger ONLY after the new file is actually in place — pruning it
                // before the copy/replace would strip the trigger off the still-intact existing
                // adapter if the copy threw.
                var dict = loadTriggers()
                if dict.removeValue(forKey: dest.lastPathComponent) != nil { saveTriggers(dict) }
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return item(for: dest, stored: loadTriggers())
    }

    /// Throws if the on-disk file can't be removed, so the UI can report a real failure
    /// instead of an unconditional "Deleted". The trigger is pruned ONLY after the file is
    /// actually gone (otherwise a still-present adapter would lose its trigger word).
    func delete(_ item: LoRAItem) throws {
        try FileManager.default.removeItem(at: item.url)
        var dict = loadTriggers()
        if dict.removeValue(forKey: item.fileName) != nil { saveTriggers(dict) }
    }

    /// Set (or clear, if empty) the trigger word for a LoRA file. Returns whether the sidecar
    /// was actually written, so the UI doesn't claim "Trigger saved" on a swallowed write error.
    @discardableResult
    func setTrigger(_ trigger: String, forFileName name: String) -> Bool {
        var dict = loadTriggers()
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { dict.removeValue(forKey: name) } else { dict[name] = t }
        return saveTriggers(dict)
    }

    private func item(for url: URL, stored: [String: String]) -> LoRAItem {
        let insp = SafetensorsInspector.inspect(at: url)
        let name = url.lastPathComponent
        // Priority: user-set trigger > auto-detected from metadata > none.
        let trigger = stored[name] ?? insp.trigger ?? ""
        return LoRAItem(id: name, fileName: name, url: url, tier: insp.tier, note: insp.note, trigger: trigger)
    }
}
