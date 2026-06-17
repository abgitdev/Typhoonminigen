import Foundation

/// Embeds and reads the generation recipe inside PNG files via a `tEXt` chunk with the
/// keyword "parameters" — the de-facto A1111 schema, so Civitai/A1111/ComfyUI readers can
/// show the recipe too. Pure Foundation byte-splicing (CGImageDestination has no tEXt API);
/// keep this file dependency-free so it stays testable outside the app.
enum PNGMetadata {

    // MARK: - Building the parameters text

    /// A1111 layout: the prompt (may span lines), then ONE final line of
    /// `Steps: …, key: value, …` — readers locate the recipe by that last line.
    static func parameters(
        prompt: String,
        steps: Int,
        guidance: Float,
        seed: UInt64,
        width: Int,
        height: Int,
        model: String,
        loras: [(name: String, scale: Float)],
        appVersion: String
    ) -> String {
        var tail = "Steps: \(steps)"
        tail += ", CFG scale: \(String(format: "%.1f", guidance))"
        tail += ", Seed: \(seed)"
        tail += ", Size: \(width)x\(height)"
        tail += ", Model: \(model)"
        if !loras.isEmpty {
            // Quoted because adapter file names may contain commas; quotes/backslashes in
            // a name are escaped; entries join with " / " — a slash can never appear
            // inside a macOS file name, so the separator is unambiguous. The LAST " @ "
            // splits name/scale (names may themselves contain " @ ").
            let list = loras.map { "\(escape($0.name)) @ \(String(format: "%.2f", $0.scale))" }
                .joined(separator: " / ")
            tail += ", Lora: \"\(list)\""
        }
        tail += ", Version: Typhoonminigen \(appVersion)"
        return prompt + "\n" + tail
    }

    // MARK: - PNG chunk splice / extract

    private static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let keyword = "parameters"
    /// Hard cap on a recipe text chunk (real recipes are a few KB; this rejects a hostile
    /// dropped PNG whose oversized "parameters" chunk would become a multi-GB prompt).
    private static let maxParametersBytes = 1_000_000

    /// Splice a `tEXt parameters` chunk right after IHDR. Non-PNG/malformed input is
    /// returned unchanged — the caller still writes a valid image, just without a recipe.
    static func embed(parameters: String, into raw: Data) -> Data {
        let data = raw.startIndex == 0 ? raw : Data(raw)   // offsets below are 0-based
        guard data.count >= 8, data.prefix(8) == signature else { return data }
        let ihdrLen = Int(readUInt32(data, at: 8))
        let insertAt = 8 + 4 + 4 + ihdrLen + 4   // signature + IHDR(len+type+data+crc)
        guard ihdrLen >= 0, insertAt <= data.count else { return data }

        // PIL (A1111's "PNG Info", ComfyUI) decodes tEXt as Latin-1 per the PNG spec, so
        // Latin-1-encodable text ships as plain tEXt for maximum compatibility; anything
        // else (non-Latin-1 prompts) goes into an uncompressed iTXt chunk — UTF-8 by spec,
        // exactly what A1111 itself writes for non-Latin-1 parameters. decodeTextChunk
        // reads both back.
        var payload = Data(keyword.utf8)
        payload.append(0)
        let chunkType: String
        if let latin1 = parameters.data(using: .isoLatin1) {
            chunkType = "tEXt"
            payload.append(latin1)
        } else {
            chunkType = "iTXt"
            payload.append(contentsOf: [0, 0])   // compression flag 0, compression method 0
            payload.append(0)                    // empty language tag, \0-terminated
            payload.append(0)                    // empty translated keyword, \0-terminated
            payload.append(Data(parameters.utf8))
        }
        let typeAndPayload = Data(chunkType.utf8) + payload

        var out = data.subdata(in: 0 ..< insertAt)
        out.append(uint32BE(UInt32(payload.count)))
        out.append(typeAndPayload)
        out.append(uint32BE(crc32(typeAndPayload)))
        out.append(data.subdata(in: insertAt ..< data.count))
        return out
    }

    /// The "parameters" text of a PNG file, or nil when absent / not a PNG.
    static func parameters(fromPNGAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return parameters(from: data)
    }

    static func parameters(from raw: Data) -> String? {
        let data = raw.startIndex == 0 ? raw : Data(raw)   // offsets below are 0-based
        guard data.count >= 8, data.prefix(8) == signature else { return nil }
        var pos = 8
        while pos + 12 <= data.count {
            let len = Int(readUInt32(data, at: pos))
            guard len >= 0, pos + 12 + len <= data.count else { return nil }
            let type = String(decoding: data.subdata(in: pos + 4 ..< pos + 8), as: UTF8.self)
            if type == "IEND" { return nil }
            if type == "tEXt" || type == "iTXt" {
                // A recipe is a few KB; refuse a hostile multi-GB chunk before materializing it
                // (the prompt would otherwise become a multi-GB string).
                guard len <= maxParametersBytes else { pos += 12 + len; continue }
                let payload = data.subdata(in: pos + 8 ..< pos + 8 + len)
                if let text = decodeTextChunk(type: type, payload: payload) { return text }
            }
            pos += 12 + len
        }
        return nil
    }

    /// Keyword-matched text of one tEXt/iTXt payload (iTXt only when uncompressed).
    private static func decodeTextChunk(type: String, payload: Data) -> String? {
        guard let zero = payload.firstIndex(of: 0) else { return nil }
        let key = String(decoding: payload.subdata(in: payload.startIndex ..< zero), as: UTF8.self)
        guard key == keyword else { return nil }
        var textStart = zero + 1
        if type == "iTXt" {
            // keyword \0 compressionFlag compressionMethod languageTag \0 translatedKeyword \0 text
            guard textStart + 2 <= payload.endIndex, payload[textStart] == 0 else { return nil }
            var cursor = textStart + 2
            for _ in 0 ..< 2 {   // skip the two \0-terminated tag fields
                guard let next = payload[cursor...].firstIndex(of: 0) else { return nil }
                cursor = next + 1
            }
            textStart = cursor
        }
        guard textStart <= payload.endIndex else { return nil }
        let body = payload.subdata(in: textStart ..< payload.endIndex)
        return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1)
    }

    // MARK: - Parsing a recipe back out

    struct Recipe {
        var prompt = ""
        var seed: UInt64? = nil
        var width: Int? = nil
        var height: Int? = nil
        var modelName: String? = nil
        var loras: [(name: String, scale: Float)] = []
        var hadNegativePrompt = false   // foreign A1111 files; Klein has no negative prompt
    }

    static func recipe(from parameters: String) -> Recipe {
        var recipe = Recipe()
        let lines = parameters.components(separatedBy: "\n")
        let paramsIdx = lines.lastIndex { $0.hasPrefix("Steps:") }
        // This app never writes a Negative-prompt line — in OUR files any such line is
        // literal prompt text the user pasted (a copied Civitai block), so don't truncate
        // the prompt at it. Foreign files keep A1111-parity truncation.
        let isOurs = paramsIdx.map { lines[$0].contains("Version: Typhoonminigen") } ?? false
        let negIdx = isOurs ? nil : lines.firstIndex { $0.hasPrefix("Negative prompt:") }
        recipe.hadNegativePrompt = negIdx != nil

        let promptEnd = [negIdx, paramsIdx].compactMap { $0 }.min() ?? lines.count
        recipe.prompt = lines[0 ..< promptEnd].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let paramsIdx else { return recipe }

        for (key, value) in keyValues(lines[paramsIdx]) {
            switch key.lowercased() {
            case "seed":
                recipe.seed = UInt64(value)
            case "size":
                let dims = value.lowercased().split(separator: "x")
                if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) {
                    recipe.width = w
                    recipe.height = h
                }
            case "model":
                recipe.modelName = value
            case "lora":
                var list = value
                if list.hasPrefix("\""), list.hasSuffix("\""), list.count >= 2 {
                    list = String(list.dropFirst().dropLast())
                }
                for entry in list.components(separatedBy: " / ") {
                    if let at = entry.range(of: " @ ", options: .backwards) {
                        let name = unescape(String(entry[..<at.lowerBound]))
                        let scale = Float(entry[at.upperBound...]) ?? 1.0
                        recipe.loras.append((name, scale))
                    } else if !entry.isEmpty {
                        recipe.loras.append((unescape(entry), 1.0))
                    }
                }
            default:
                break
            }
        }
        return recipe
    }

    /// Split `Steps: 4, CFG scale: 1.0, Lora: "a, b"` into key/value pairs, honoring
    /// double quotes (values may contain commas) and backslash-escaped quotes inside them.
    private static func keyValues(_ line: String) -> [(String, String)] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\", inQuotes {
                current.append(ch)
                escaped = true
            } else if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == ",", !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.compactMap { part in
            guard let colon = part.firstIndex(of: ":") else { return nil }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces)
            let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, value)
        }
    }

    /// Escape a LoRA file name for the quoted Lora value (A1111-style backslash escapes).
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func unescape(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    // MARK: - Byte helpers

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        guard i + 4 <= data.endIndex else { return 0 }
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16)
             | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    private static func uint32BE(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { n in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
