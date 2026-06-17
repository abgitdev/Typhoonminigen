import Foundation

/// A persisted record of one generated image. Pure Foundation (no engine import) so the
/// gallery/persistence layer stays decoupled from engine types.
struct Generation: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let prompt: String
    let seed: UInt64
    let modelTier: String        // ModelTier.rawValue
    let steps: Int
    let guidance: Float
    let width: Int
    let height: Int
    let loraName: String?        // legacy single-LoRA fields (records before dual LoRA);
    let loraScale: Float?        // new saves fill them with the FIRST applied adapter
    let loras: [LoRAUse]?        // full applied set (≤2), nil for old records / no LoRA
    let createdAt: Date
    let imageFileName: String    // relative to AppPaths.images
    let referenceImagePath: String?      // legacy single reference (records before v0.30)
    let referenceImagePaths: [String]?   // I2I reference file paths (up to 3, informational)
    let durationSeconds: Double?     // wall-clock seconds the generation took (nil for old records)

    init(
        id: UUID = UUID(),
        prompt: String,
        seed: UInt64,
        modelTier: String,
        steps: Int,
        guidance: Float,
        width: Int,
        height: Int,
        loraName: String? = nil,
        loraScale: Float? = nil,
        loras: [LoRAUse]? = nil,
        createdAt: Date = Date(),
        imageFileName: String,
        referenceImagePath: String? = nil,
        referenceImagePaths: [String]? = nil,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.seed = seed
        self.modelTier = modelTier
        self.steps = steps
        self.guidance = guidance
        self.width = width
        self.height = height
        self.loraName = loraName
        self.loraScale = loraScale
        self.loras = loras
        self.createdAt = createdAt
        self.imageFileName = imageFileName
        self.referenceImagePath = referenceImagePath
        self.referenceImagePaths = referenceImagePaths
        self.durationSeconds = durationSeconds
    }

    /// Absolute URL of the image on disk.
    var imageURL: URL { AppPaths.images.appendingPathComponent(imageFileName) }

    /// Applied-LoRA display lines ("name @ 0.50") — new multi field, legacy fallback.
    var loraSummary: [String] {
        if let loras, !loras.isEmpty {
            return loras.map { "\($0.name) @ \(String(format: "%.2f", $0.scale))" }
        }
        if let loraName {
            if let loraScale { return ["\(loraName) @ \(String(format: "%.2f", loraScale))"] }
            return [loraName]
        }
        return []
    }

    /// Reference file names for display — new multi-ref field, falling back to the legacy one.
    var referenceNames: [String] {
        if let paths = referenceImagePaths, !paths.isEmpty {
            return paths.map { ($0 as NSString).lastPathComponent }
        }
        if let single = referenceImagePath { return [(single as NSString).lastPathComponent] }
        return []
    }
}
