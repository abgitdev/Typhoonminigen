import Foundation

/// View-friendly description of one manageable model tier (its transformer).
struct ModelInfo: Identifiable, Sendable {
    let id: String            // ModelTier.rawValue
    let tier: ModelTier
    let title: String
    let estimatedSizeGB: Int
    let isGated: Bool
    let isDownloaded: Bool
    let isEncoderDownloaded: Bool   // tier's Qwen3 encoder present (8-bit or 4-bit dir)
    let downloadedBytes: Int64
    let license: String
}
