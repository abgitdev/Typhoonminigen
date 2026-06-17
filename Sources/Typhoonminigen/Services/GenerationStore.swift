import Foundation
import CoreGraphics

/// Owns the gallery on disk: PNG files in AppPaths.images + a JSON index of metadata.
/// An actor so saves/deletes are serialized and safe to call from anywhere.
actor GenerationStore {
    private(set) var generations: [Generation] = []

    init() {
        generations = Self.loadFromDisk()
    }

    // MARK: Persistence

    /// Decodes ONE array element, capturing a per-record decode failure as nil instead of
    /// aborting the whole array — so a single malformed record can't vanish the entire gallery.
    private struct FailableGeneration: Decodable {
        let value: Generation?
        init(from decoder: Decoder) throws { value = try? Generation(from: decoder) }
    }

    /// Static (non-isolated) so it can run from the actor's init. A clean index decodes whole;
    /// otherwise we SALVAGE every still-decodable record (one bad entry no longer wipes the
    /// gallery), rewrite a clean index immediately, and quarantine the original for evidence.
    private static func loadFromDisk() -> [Generation] {
        let url = AppPaths.generationsIndex
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        if let list = try? JSONDecoder().decode([Generation].self, from: data) {
            return list.sorted { $0.createdAt > $1.createdAt }
        }
        // Quarantine the unreadable original (orphan PNGs stay on disk, recoverable).
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantine = url.deletingLastPathComponent()
            .appendingPathComponent("generations.corrupt.\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: quarantine)
        // Lenient pass: keep whatever records ARE decodable.
        if let lenient = try? JSONDecoder().decode([FailableGeneration].self, from: data) {
            let salvaged = lenient.compactMap(\.value).sorted { $0.createdAt > $1.createdAt }
            if !salvaged.isEmpty {
                // Persist the salvage NOW so it survives a crash before the next save/delete.
                if let clean = try? JSONEncoder().encode(salvaged) { try? clean.write(to: url, options: .atomic) }
                AppLog.error("generations.json: salvaged \(salvaged.count) record(s), dropped \(lenient.count - salvaged.count) — original saved as \(quarantine.lastPathComponent)")
                return salvaged
            }
        }
        AppLog.error("generations.json corrupt → saved as \(quarantine.lastPathComponent)")
        return []
    }

    /// Throws on write failure so callers can react (vs. silently "succeeding").
    private func persist() throws {
        let data = try JSONEncoder().encode(generations)
        try data.write(to: AppPaths.generationsIndex, options: .atomic)
    }

    // MARK: API

    func all() -> [Generation] { generations }

    /// Save the PNG + append the metadata record. If the index write fails, the just-written
    /// PNG is removed (no orphan) and the error is rethrown.
    @discardableResult
    func save(image: CGImage, request: GenerationRequest, seed: UInt64, duration: Double? = nil) throws -> Generation {
        let fileName = "flux_\(UUID().uuidString)_\(seed).png"  // N-3: UUID prevents same-second collisions
        // The full recipe rides inside the PNG itself (A1111 "parameters" tEXt chunk) —
        // a shared/re-downloaded file can be dropped back on the canvas to restore it.
        let parameters = PNGMetadata.parameters(
            prompt: request.prompt,
            steps: request.steps,
            guidance: request.guidance,
            seed: seed,
            width: request.width,
            height: request.height,
            model: "FLUX.2 \(request.tier.shortName)",
            loras: request.loras.map { ($0.name, $0.scale) },
            appVersion: AppVersion.current
        )
        let fileURL = try ImageSaver.savePNG(image, into: AppPaths.images, name: fileName,
                                             parameters: parameters)

        let gen = Generation(
            prompt: request.prompt,
            seed: seed,
            modelTier: request.tier.rawValue,
            steps: request.steps,
            guidance: request.guidance,
            width: request.width,
            height: request.height,
            loraName: request.loras.first?.name,
            loraScale: request.loras.first?.scale,
            loras: request.loras.isEmpty ? nil : request.loras,
            imageFileName: fileName,
            referenceImagePaths: request.referenceImagePaths,
            durationSeconds: duration
        )
        generations.insert(gen, at: 0)
        do {
            try persist()
        } catch {
            generations.removeFirst()
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        return gen
    }

    /// Delete one generation — removes the PNG file, its upscaled copies, and the record.
    func delete(_ id: UUID) {
        guard let idx = generations.firstIndex(where: { $0.id == id }) else { return }
        let gen = generations.remove(at: idx)
        do {
            try FileManager.default.removeItem(at: gen.imageURL)
        } catch {
            // Visible instead of swallowed: a stuck file becomes an un-indexed orphan that
            // only deleteAll's sweep would catch.
            AppLog.error("Couldn't remove \(gen.imageFileName): \(error.localizedDescription)")
        }
        removeUpscales(of: gen)
        // S-2: rollback in-memory state if the index write fails (prevents ghost entries on restart)
        do {
            try persist()
        } catch {
            generations.insert(gen, at: idx)
            AppLog.error("Error deleting gallery entry: \(error.localizedDescription)")
        }
    }

    /// Delete several generations at once (#9) — removes each PNG + its ×2/×4 upscales, then
    /// persists the index ONCE instead of N times. Returns the number of files removed.
    @discardableResult
    func deleteMany(_ ids: [UUID]) -> Int {
        let idSet = Set(ids)
        let victims = generations.filter { idSet.contains($0.id) }
        guard !victims.isEmpty else { return 0 }
        generations.removeAll { idSet.contains($0.id) }
        var removed = 0
        for gen in victims {
            do { try FileManager.default.removeItem(at: gen.imageURL); removed += 1 }
            catch { AppLog.error("Couldn't remove \(gen.imageFileName): \(error.localizedDescription)") }
            removeUpscales(of: gen)
        }
        do { try persist() }
        catch { AppLog.error("Error persisting after batch delete: \(error.localizedDescription)") }
        return removed
    }

    /// Upscaled copies live next to the base as `<stem>_x2.png` / `<stem>_x4.png` (plus a
    /// possible `<stem>_x4_tmp_*.png` stray) and are not indexed — remove them with their
    /// base or they pile up as invisible orphans (forensic-audit finding).
    private func removeUpscales(of gen: Generation) {
        let fm = FileManager.default
        let stem = (gen.imageFileName as NSString).deletingPathExtension
        guard let files = try? fm.contentsOfDirectory(at: AppPaths.images, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix(stem + "_x") {
            try? fm.removeItem(at: f)
        }
    }

    /// Delete ALL generations — indexed PNGs AND any orphan `flux_*.png` (from failed/corrupt
    /// saves). Returns files removed + bytes reclaimed.
    @discardableResult
    func deleteAll() -> (count: Int, bytes: Int64) {
        // S-3: write empty index to disk FIRST — if file deletion then fails, the gallery is
        // at least consistent (empty index, maybe stale files; not the reverse: full index + no files).
        let snapshot = generations
        generations.removeAll()
        do {
            try persist()
        } catch {
            generations = snapshot  // rollback if we can't even write the empty index
            AppLog.error("Error clearing gallery: \(error.localizedDescription)")
            return (0, 0)
        }

        let fm = FileManager.default
        var bytes: Int64 = 0
        var count = 0
        var seen = Set<String>()

        func removeFile(_ url: URL) {
            if let n = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
                bytes += n.int64Value
            }
            if (try? fm.removeItem(at: url)) != nil { count += 1 }
        }

        for gen in snapshot {
            seen.insert(gen.imageFileName)
            removeFile(gen.imageURL)
        }
        if let files = try? fm.contentsOfDirectory(at: AppPaths.images, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension.lowercased() == "png"
                && f.lastPathComponent.hasPrefix("flux_")
                && !seen.contains(f.lastPathComponent) {
                removeFile(f)
            }
        }
        return (count, bytes)
    }

    /// Reset for "Remove all data": the System wipe deletes the whole appSupport dir (PNGs +
    /// index) on disk but can't touch this in-memory array — so the gallery would keep showing N
    /// "missing" ghost cards. Clear the array AND rewrite a clean empty index (recreating
    /// appSupport) so the gallery shows 0 and a later save can still persist. Call AFTER the disk
    /// wipe (MaintenanceService.removeAllData).
    func reset() {
        generations.removeAll()
        try? FileManager.default.createDirectory(at: AppPaths.appSupport, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode([Generation]()) {
            try? data.write(to: AppPaths.generationsIndex, options: .atomic)
        }
    }
}
