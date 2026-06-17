import Foundation

/// How an imported component lands in the app's Models dir.
enum ImportMode: Sendable {
    /// FileManager.copyItem — on the same APFS volume this is an instant copy-on-write
    /// clone (no extra space until either side changes).
    case copy
    /// Symlink pointing at the user's original — zero disk cost, but the original must
    /// stay in place; deleting the row later removes only the link.
    case link
}

/// A model component the import flow can recognize and place. Target paths are the EXACT
/// directory names the engine resolves at load time — anything else is invisible to it.
enum ImportableComponent: CaseIterable, Sendable, Hashable {
    case transformer4B, transformer9B, vae, qwen4B, qwen4B4bit, qwen8B, qwenVLM35

    /// Canonical location under the app's Models root.
    var relPath: String {
        switch self {
        case .transformer4B: return "black-forest-labs/FLUX.2-klein-4B-klein4b-8bit"
        case .transformer9B: return "black-forest-labs/FLUX.2-klein-9B-klein9b-bf16"
        case .vae:           return "black-forest-labs/FLUX.2-klein-4B-vae"
        case .qwen4B:        return "lmstudio-community/Qwen3-4B-MLX-8bit"
        case .qwen4B4bit:    return "lmstudio-community/Qwen3-4B-MLX-4bit"
        case .qwen8B:        return "lmstudio-community/Qwen3-8B-MLX-8bit"
        case .qwenVLM35:     return "mlx-community/Qwen3.5-4B-MLX-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .transformer4B: return "Klein 4B transformer"
        case .transformer9B: return "Klein 9B transformer"
        case .vae:           return "Shared VAE"
        case .qwen4B:        return "Qwen3-4B text encoder"
        case .qwen4B4bit:    return "Qwen3 4B encoder (4-bit)"
        case .qwen8B:        return "Qwen3-8B text encoder"
        case .qwenVLM35:     return "Qwen3.5-VLM (Describe)"
        }
    }
}

struct FoundComponent: Identifiable, Sendable {
    let component: ImportableComponent
    let sourceURL: URL
    let sizeBytes: Int64
    let alreadyInstalled: Bool
    var id: String { component.relPath }
}

enum ModelImportError: LocalizedError {
    case targetExists(String)
    case insufficientDisk(needed: Int64, free: Int64)
    case brokenSourceLink(String)

    var errorDescription: String? {
        switch self {
        case .targetExists(let name):
            return "\(name) is already installed — delete it on the Models tab first."
        case .insufficientDisk(let needed, let free):
            return "Not enough disk space to copy: needs \(ByteFormat.string(needed)), only \(ByteFormat.string(free)) available. Use Link instead, or free up space."
        case .brokenSourceLink(let name):
            return "The source folder contains a broken link (\(name)) — its destination is missing. Fix or remove it and try again."
        }
    }
}

/// Validates a user-picked folder of MLX weights and installs recognized components into
/// the app's Models dir. Identification is by file SIGNATURE (gate file + config keys +
/// weight layout), never by directory name — and mirrors the engine's verifyModel
/// completeness rules so an imported dir is guaranteed to light up in the catalog.
/// Pure FileManager work; safe off the main actor.
enum ModelImportService {

    /// Examines the folder itself, its children and grandchildren — handles both a model
    /// dir picked directly and a parent "Models/org/repo" tree. Dirs without config.json
    /// or model_index.json never qualify, so ComfyUI single-file checkpoints fail here.
    static func scan(folder: URL) -> [FoundComponent] {
        var results: [FoundComponent] = []
        var seen = Set<ImportableComponent>()
        for dir in candidateDirs(in: folder) {
            guard let component = identify(dir), !seen.contains(component) else { continue }
            seen.insert(component)
            let target = AppPaths.models.appendingPathComponent(component.relPath, isDirectory: true)
            results.append(FoundComponent(
                component: component,
                sourceURL: dir,
                sizeBytes: directorySize(dir),
                alreadyInstalled: FileManager.default.fileExists(atPath: target.path)
                    && isComplete(component, at: target)))
        }
        let order = ImportableComponent.allCases
        return results.sorted {
            (order.firstIndex(of: $0.component) ?? 0) < (order.firstIndex(of: $1.component) ?? 0)
        }
    }

    static func install(_ found: FoundComponent, mode: ImportMode) throws {
        let fm = FileManager.default
        let target = AppPaths.models.appendingPathComponent(found.component.relPath, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            guard !isComplete(found.component, at: target) else {
                throw ModelImportError.targetExists(found.component.displayName)
            }
            // Incomplete leftover (e.g. a failed earlier copy) — replaceable.
            try fm.removeItem(at: target)
        } else if (try? fm.attributesOfItem(atPath: target.path)) != nil {
            // fileExists FOLLOWS symlinks, so a DANGLING link (the linked original was moved
            // or deleted) reads as "absent" yet still occupies the path — createSymbolicLink/
            // deepCopy below would then throw a confusing 'file exists'. lstat sees it; clear it.
            try? fm.removeItem(at: target)
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch mode {
        case .copy:
            do {
                // Preflight only across volumes — a same-volume APFS clone costs ~nothing.
                let source = found.sourceURL.resolvingSymlinksInPath()
                let srcVol = try? source.resourceValues(forKeys: [.volumeURLKey]).volume
                let dstVol = try? AppPaths.models.resourceValues(forKeys: [.volumeURLKey]).volume
                let sameVolume = srcVol != nil && srcVol == dstVol
                if !sameVolume,
                   let free = try? AppPaths.models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   free < found.sizeBytes {
                    throw ModelImportError.insufficientDisk(needed: found.sizeBytes, free: free)
                }
                try deepCopy(from: source, to: target)
            } catch {
                // Never leave a half-copied dir behind — it would read as installed.
                try? fm.removeItem(at: target)
                throw error
            }
        case .link:
            try fm.createSymbolicLink(at: target, withDestinationURL: found.sourceURL)
        }
    }

    /// Removes dangling symlinks at known component paths (the user moved or deleted a
    /// linked original) so the catalog doesn't show dead rows. Swallows per-item errors.
    static func sweepDanglingLinks(under root: URL) {
        let fm = FileManager.default
        for component in ImportableComponent.allCases {
            let url = root.appendingPathComponent(component.relPath)
            // attributesOfItem is the non-following (lstat) API; fileExists follows.
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeSymbolicLink,
                  !fm.fileExists(atPath: url.path) else { continue }
            try? fm.removeItem(at: url)
            AppLog.info("Removed dangling model link: \(component.relPath)")
        }
    }

    /// copyItem replicates symlinks verbatim — an HF-cache source full of blob links would
    /// land as links into the user's cache. Walk the tree and materialize real contents.
    private static func deepCopy(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for entry in entries {
            var src = entry
            if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                src = entry.resolvingSymlinksInPath()
                guard fm.fileExists(atPath: src.path) else {
                    throw ModelImportError.brokenSourceLink(entry.lastPathComponent)
                }
            }
            let dst = target.appendingPathComponent(entry.lastPathComponent)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue {
                try deepCopy(from: src, to: dst)
            } else {
                try fm.copyItem(at: src, to: dst)
            }
        }
    }

    // MARK: Identification

    private static func candidateDirs(in root: URL) -> [URL] {
        var dirs = [root]
        let children = subdirectories(of: root)
        dirs += children
        for child in children { dirs += subdirectories(of: child) }
        return dirs
    }

    private static func subdirectories(of url: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        // fileExists(isDirectory:) traverses symlinks — a linked model dir still qualifies.
        return items.filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    private static func identify(_ dir: URL) -> ImportableComponent? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.resolvingSymlinksInPath().path) else { return nil }
        let files = Set(names)

        if files.contains("model_index.json") {
            // 9B layout: single weight file, accepted by the engine's "flux-2-klein" prefix match.
            // The official 4B bf16 repo has the SAME layout — require the "-9b" name or real
            // 9B bulk (18.16 GB vs ~7.75 GB) so it can't masquerade as the 9B tier. It is NOT
            // the 4B slot either: that tier is the quanto-8bit build with config.json.
            guard let weight = names.first(where: { $0.hasPrefix("flux-2-klein") && $0.hasSuffix(".safetensors") })
            else { return nil }
            if weight.lowercased().hasPrefix("flux-2-klein-9b") { return .transformer9B }
            let size = fileSize(dir.appendingPathComponent(weight).resolvingSymlinksInPath())
            return size > 12_000_000_000 ? .transformer9B : nil
        }
        guard files.contains("config.json") else { return nil }
        let config = loadJSON(dir.appendingPathComponent("config.json"))

        if files.contains("diffusion_pytorch_model.safetensors") {
            switch config?["_class_name"] as? String {
            case "AutoencoderKLFlux2": return .vae
            case "Flux2Transformer2DModel": return .transformer4B
            default:
                // No class key — split by weight size (VAE ≈ 168 MB, 4B transformer ≈ 3.9 GB).
                let size = fileSize(dir.appendingPathComponent("diffusion_pytorch_model.safetensors"))
                if size > 1_000_000_000 { return .transformer4B }
                if size > 0 && size < 500_000_000 { return .vae }
                return nil
            }
        }

        // Qwen family — the engine needs the tokenizer set at encode time, so an
        // incomplete dir must not be importable.
        guard files.contains("tokenizer.json"), files.contains("tokenizer_config.json"),
              hasCompleteWeights(names: names, files: files) else { return nil }
        let modelType = (config?["model_type"] as? String) ?? ""
        let arch = ((config?["architectures"] as? [String]) ?? []).joined()
        // The engine dirs are all quantized MLX builds — a config without a quantization
        // dict is a full-precision export and would not match any slot.
        let bits = (config?["quantization"] as? [String: Any])?["bits"] as? Int
        if modelType == "qwen3_5" || arch.contains("Qwen3_5") {
            return bits == 4 ? .qwenVLM35 : nil
        }
        guard modelType == "qwen3" || arch.contains("Qwen3ForCausalLM") else { return nil }
        let is8B: Bool
        switch config?["hidden_size"] as? Int {
        case 2560: is8B = false
        case 4096: is8B = true
        default:
            // hidden_size missing — total weight size splits 4B (~4.3 GB) from 8B (~8.7 GB).
            is8B = directorySize(dir) >= 6_500_000_000
        }
        if is8B { return bits == 8 ? .qwen8B : nil }
        switch bits {
        case 8: return .qwen4B
        case 4: return .qwen4B4bit
        default: return nil
        }
    }

    /// Per-component completeness, mirroring the engine's verifyModel rules. Used for both
    /// the SOURCE (importable?) and the TARGET (already installed vs replaceable stub).
    private static func isComplete(_ component: ImportableComponent, at dir: URL) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.resolvingSymlinksInPath().path)
        else { return false }
        let files = Set(names)
        switch component {
        case .transformer9B:
            return files.contains("model_index.json")
                && names.contains { $0.hasPrefix("flux-2-klein") && $0.hasSuffix(".safetensors") }
        case .transformer4B, .vae:
            return files.contains("config.json")
                && files.contains("diffusion_pytorch_model.safetensors")
        case .qwen4B, .qwen4B4bit, .qwen8B, .qwenVLM35:
            return files.contains("config.json") && files.contains("tokenizer.json")
                && files.contains("tokenizer_config.json")
                && hasCompleteWeights(names: names, files: files)
        }
    }

    /// Mirrors the engine's verifyModel: single model.safetensors, or a COMPLETE
    /// model-NNNNN-of-MMMMM shard series plus its index.
    private static func hasCompleteWeights(names: [String], files: Set<String>) -> Bool {
        if files.contains("model.safetensors") { return true }
        guard files.contains("model.safetensors.index.json") else { return false }
        var total = 0
        var found = Set<Int>()
        for n in names {
            guard n.hasPrefix("model-"), n.hasSuffix(".safetensors") else { continue }
            let stem = n.dropFirst("model-".count).dropLast(".safetensors".count)
            let parts = stem.split(separator: "-")
            guard parts.count == 3, parts[1] == "of",
                  let idx = Int(parts[0]), let tot = Int(parts[2]) else { continue }
            if total == 0 { total = tot }
            guard tot == total else { return false }
            found.insert(idx)
        }
        return total > 0 && (1...total).allSatisfy(found.contains)
    }

    private static func loadJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        // Resolve first — an enumerator rooted at a symlink yields zero items.
        if let en = fm.enumerator(at: url.resolvingSymlinksInPath(), includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
