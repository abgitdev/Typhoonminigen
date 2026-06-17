import Foundation

/// A LoRA adapter file on disk + the result of inspecting its safetensors header.
struct LoRAItem: Identifiable, Sendable, Hashable {
    let id: String          // fileName
    let fileName: String
    let url: URL
    let tier: ModelTier?    // detected target tier; nil = incompatible / unknown
    let note: String        // human-readable detection result
    var trigger: String     // activation keyword; "" if none (auto-added to prompt at generation)

    var isCompatible: Bool { tier != nil }
}

/// One LoRA applied to a generation. The engine fuses adapters sequentially and their
/// weight deltas SUM, so up to 2 can be combined; each carries its own scale.
/// Codable because gallery records persist the applied set (path is informational —
/// like referenceImagePaths, it may go stale if the file is later deleted).
struct LoRAUse: Sendable, Hashable, Codable {
    let path: String
    let name: String
    let scale: Float
}
