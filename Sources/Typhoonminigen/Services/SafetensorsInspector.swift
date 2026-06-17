import Foundation

/// Result of reading a LoRA's safetensors header (no tensor data loaded).
struct LoRAInspection: Sendable {
    let tier: ModelTier?
    let note: String
    let trigger: String?   // auto-detected from metadata, if the file stored one
}

/// Reads a `.safetensors` JSON header (8-byte little-endian length + JSON) WITHOUT loading
/// tensor data, classifies the Klein tier, and tries to read a trigger keyword.
enum SafetensorsInspector {
    static func inspect(at url: URL) -> LoRAInspection {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return LoRAInspection(tier: nil, note: "couldn't open file", trigger: nil)
        }
        defer { try? handle.close() }

        guard let lenData = try? handle.read(upToCount: 8), lenData.count == 8 else {
            return LoRAInspection(tier: nil, note: "corrupt header", trigger: nil)
        }
        let headerLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        guard headerLen > 0, headerLen < 50_000_000 else {
            return LoRAInspection(tier: nil, note: "invalid header", trigger: nil)
        }
        guard let headerData = try? handle.read(upToCount: Int(headerLen)),
              headerData.count == Int(headerLen),
              let json = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            return LoRAInspection(tier: nil, note: "couldn't parse header", trigger: nil)
        }

        let (tier, note) = classify(json)
        return LoRAInspection(tier: tier, note: note, trigger: readTrigger(json))
    }

    /// PRIMARY: classify by the MAX block index across double/single stream blocks. Handles BFL
    /// (`double_blocks`/`single_blocks`) and Diffusers (`transformer_blocks`/`single_transformer_blocks`)
    /// naming with any prefix (e.g. `diffusion_model.`). Block counts identify the exact architecture
    /// (4B = 5/20, 9B = 8/24; Dev/FLUX.1 rejected) — the inner dim alone CANNOT, since FLUX.1 and
    /// Klein 4B can both be 3072. Both audits (Codex + Sonnet) independently recommended this.
    private static func classify(_ json: [String: Any]) -> (ModelTier?, String) {
        // Engine-loadability gate FIRST: the engine's LoRALoader parses ONLY diffusers
        // `.lora_A.weight` / `.lora_B.weight` keys and silently skips everything else —
        // a kohya/sd-scripts file (lora_down/lora_up, the dominant Civitai naming) would
        // merge as a NO-OP, so any "compatible" badge for it is a lie. FLUX.1 kohya files
        // also dodge the block scan (underscore separators) and land on dim 3072 ＝ Klein 4B,
        // which is exactly the false-accept this gate prevents.
        let keys = json.keys.filter { $0 != "__metadata__" }
        if !keys.contains(where: { $0.contains(".lora_A.") || $0.contains(".lora_B.") }) {
            // LyCORIS variants store a different math (LoKr = Kronecker w1⊗w2, LoHa = Hadamard),
            // not the A·B low-rank the engine merges — name them so the rejection is understandable.
            if keys.contains(where: { $0.contains("lokr_") }) {
                return (nil, "LoKr / LyCORIS adapter — this app loads standard LoRA only")
            }
            if keys.contains(where: { $0.contains("hada_") }) {
                return (nil, "LoHa / LyCORIS adapter — this app loads standard LoRA only")
            }
            if keys.contains(where: { $0.contains("lora_down") || $0.contains("lora_up") }) {
                return (nil, "kohya-format LoRA — the engine needs diffusers lora_A/lora_B naming")
            }
            return (nil, "no lora_A/lora_B tensors — not a diffusers-format LoRA")
        }
        var maxDouble = -1, maxSingle = -1
        for key in json.keys where key != "__metadata__" {
            // single first (its name contains "transformer_blocks" too — avoid miscount)
            if let n = blockIndex(key, "single_blocks.") ?? blockIndex(key, "single_transformer_blocks.") {
                maxSingle = max(maxSingle, n)
            } else if let n = blockIndex(key, "double_blocks.") ?? blockIndex(key, "transformer_blocks.") {
                maxDouble = max(maxDouble, n)
            }
        }
        switch (maxDouble, maxSingle) {
        case (4, 19): return (.klein4B, "Klein 4B (5 double / 20 single)")
        case (7, 23): return (.klein9B, "Klein 9B (8 double / 24 single)")
        case (7, 47): return (nil, "FLUX.2 Dev — not supported")
        default:
            // No EXACT block match. A LoRA that only trains a SUBSET of blocks (attention-only,
            // first-N layers — common on Civitai/HF) never reaches the last block, so its max is
            // below (7,23)/(4,19) and the old code wrongly rejected it as "incompatible". The inner
            // dim is architecture-defining and reliable even for partial LoRAs: dim 4096 is
            // UNAMBIGUOUS (FLUX.1 never uses it) → accept 9B outright. dim 3072 is shared with
            // FLUX.1, so still require the block counts to stay within Klein 4B's range
            // (≤4 double / ≤19 single); a higher count means FLUX.1's larger transformer.
            let (dimTier, dimNote) = classifyByDim(json)
            if dimTier == .klein9B { return (.klein9B, dimNote) }
            if dimTier == .klein4B, maxDouble <= 4, maxSingle <= 19 { return (.klein4B, dimNote) }
            if maxDouble < 0, maxSingle < 0 { return (dimTier, dimNote) }   // unusual naming: trust the dim verdict
            return (nil, "incompatible (blocks \(maxDouble)/\(maxSingle)) — likely FLUX.1 / another model")
        }
    }

    private static func blockIndex(_ key: String, _ marker: String) -> Int? {
        guard let r = key.range(of: marker) else { return nil }
        return Int(key[r.upperBound...].prefix(while: { $0.isNumber }))
    }

    /// Fallback: dominant inner dim of lora_A tensors (4B=3072, 9B=4096, Dev=6144).
    private static func classifyByDim(_ json: [String: Any]) -> (ModelTier?, String) {
        var dims: [Int: Int] = [:]
        for (key, value) in json {
            guard key != "__metadata__",
                  key.contains("lora_A") || key.contains("lora_down"),
                  let obj = value as? [String: Any],
                  let shape = obj["shape"] as? [NSNumber], !shape.isEmpty else { continue }
            dims[shape.map { $0.intValue }.max() ?? 0, default: 0] += 1
        }
        switch dims.max(by: { $0.value < $1.value })?.key ?? 0 {
        case 4096: return (.klein9B, "Klein 9B (dim 4096)")
        case 3072: return (.klein4B, "Klein 4B (dim 3072)")
        case 6144, 15360: return (nil, "FLUX.2 Dev — not supported")
        default: return (nil, "doesn't look like a FLUX.2 Klein LoRA")
        }
    }

    private static func readTrigger(_ json: [String: Any]) -> String? {
        guard let meta = json["__metadata__"] as? [String: Any] else { return nil }
        for k in ["modelspec.trigger_phrase", "activation_text", "trigger_words",
                  "ss_trigger_words", "trigger", "instance_prompt"] {
            if let v = meta[k] as? String {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                // Cap untrusted metadata: this string is auto-appended to the generation prompt.
                if !t.isEmpty, t.lowercased() != "none", t != "[]" { return String(t.prefix(200)) }
            }
        }
        return nil
    }
}
