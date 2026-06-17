import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Writes a CGImage to a PNG on disk.
enum ImageSaver {
    /// PNG-encode in memory — callers can splice metadata into the bytes before writing.
    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }

    /// `parameters` (the A1111 recipe text) is embedded as a PNG tEXt chunk when given —
    /// gallery images carry their recipe; thumbnails and other internal PNGs pass nil.
    @discardableResult
    static func savePNG(_ image: CGImage, into dir: URL, name: String? = nil,
                        parameters: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = name ?? "flux_\(Int(Date().timeIntervalSince1970)).png"
        let url = dir.appendingPathComponent(fileName)
        var data = try pngData(image)
        if let parameters {
            data = PNGMetadata.embed(parameters: parameters, into: data)
        }
        // Atomic: the gallery's only copy of the user's irreplaceable output — a crash/power-loss
        // mid-write must not leave a truncated, undecodable PNG that the index still references.
        try data.write(to: url, options: .atomic)
        return url
    }
}
