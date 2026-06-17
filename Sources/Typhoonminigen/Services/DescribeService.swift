import Foundation
import CoreGraphics
import FluxTextEncoders

/// Describes reference images with the small Qwen3.5-VLM 4B (4-bit, ~3 GB) and returns
/// FLUX-ready prose (the engine ships a dedicated FLUX.2 description system prompt).
///
/// This is the SAFE replacement for the engine's Mistral-24B interpret path that froze
/// the 32 GB M4: download (once) → load → describe → unload. The VLM coexists with a
/// resident Klein (~3 GB on top) — no swap risk.
enum DescribeService {
    static let variant = Qwen35Variant.qwen35_4B_4bit

    static var isModelDownloaded: Bool {
        TextEncoderModelDownloader.isQwen35ModelDownloaded(variant: variant)
    }

    /// Download if needed, load, describe every image, then unload. Status strings are
    /// streamed to `onStatus`. The blocking inference runs OFF the main thread.
    static func describe(
        images: [CGImage],
        context: String?,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> [String] {
        onStatus(isModelDownloaded ? "Loading Qwen3.5-VLM…"
                                   : "Downloading Qwen3.5-VLM (~3 GB, one time)…")
        let path = try await TextEncoderModelDownloader().downloadQwen35(variant: variant) { p, _ in
            if p < 1 { onStatus("Downloading Qwen3.5-VLM… \(Int(p * 100))%") }
        }
        try await FluxTextEncoders.shared.loadQwen35VLM(from: path.path)
        do {
            var out: [String] = []
            for (i, img) in images.enumerated() {
                // Honor a user Cancel between images (one image's inference itself is
                // uninterruptible, ~10-30 s; the download above cancels natively).
                try Task.checkCancellation()
                onStatus(images.count > 1 ? "Describing reference \(i + 1) of \(images.count)…"
                                          : "Describing reference…")
                // describeImageForFlux is synchronous and heavy (~10–30 s) — keep it off-main
                // even if the caller awaited us from the MainActor.
                let result = try await Task.detached(priority: .userInitiated) {
                    try FluxTextEncoders.shared.describeImageForFlux(image: img, context: context)
                }.value
                out.append(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            await MainActor.run { FluxTextEncoders.shared.unloadQwen35VLM() }
            return out
        } catch {
            await MainActor.run { FluxTextEncoders.shared.unloadQwen35VLM() }
            throw error
        }
    }
}
