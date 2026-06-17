import Foundation

/// One clickable prompt modifier. `label` is the short chip text; `phrase` is the
/// natural-language fragment appended to the prompt (FLUX.2/Klein wants descriptive
/// phrases, NOT bare keyword tags or SD weight syntax — verified against BFL guidance).
/// Honesty badge shown on a chip/recipe/studio. green = Klein nails it; yellow = a believable
/// IMAGE but not an exportable asset / not consistent / not real-3D (carries a `note`); red is a
/// trap that is NOT shipped as a chip (it lives only in the red panel).
enum PresetBadge: String, Codable, Sendable {
    case green, yellow, red
}

struct PromptPreset: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let phrase: String
    var badge: PresetBadge = .green
    /// Short honesty/limit line for 🟡 chips (e.g. "a flat raster image, not a real SVG"). nil = none.
    var note: String? = nil

    // Identity is the id only — adding badge/note must not change equality/hashing semantics.
    static func == (a: PromptPreset, b: PromptPreset) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One-tap LOOK — a curated set of chips applied together (clear-then-set, like the
/// style bundles in Leonardo/Canva/Freepik). ~32–44 words each, so with a short subject
/// prompt the total lands in (or near) Klein's 40–70-word sweet spot.
struct PresetBundle: Identifiable, Sendable {
    let id: String
    let label: String
    let chipIDs: [String]
    var note: String? = nil
}

/// Top-level section headers shown in the Presets card. Declaration order = on-screen
/// order: Scene first (lighting is the highest-impact axis per BFL), Subject last —
/// most generations don't need a pose/expression chip at all.
enum PromptPresetGroup: String, CaseIterable, Identifiable, Sendable {
    case scene
    case composition
    case look
    case subject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scene:       return "Scene"
        case .composition: return "Composition"
        case .look:        return "Look"
        case .subject:     return "Subject"
        }
    }

    var categories: [PromptPresetCategory] {
        switch self {
        case .scene:       return [.lighting, .environment]
        case .composition: return [.framing, .layout, .angle, .lens]
        case .look:        return [.style, .color]
        case .subject:     return [.pose, .expression, .placement]
        }
    }
}

/// Preset categories — each is one clean axis (one concept only). `appendOrder` = the
/// order phrases are appended to the prompt (BFL formula; decoupled from display order).
enum PromptPresetCategory: String, CaseIterable, Identifiable, Sendable {
    case pose
    case expression
    case placement
    case framing
    case layout
    case angle
    case lens
    case environment
    case lighting
    case style
    case color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pose:        return "Pose"
        case .expression:  return "Expression"
        case .placement:   return "Object & placement"
        case .framing:     return "Framing"
        case .layout:      return "Layout"
        case .angle:       return "Angle"
        case .lens:        return "Lens & focus"
        case .environment: return "Environment"
        case .lighting:    return "Lighting"
        case .style:       return "Style"
        case .color:       return "Color & film"   // title only — rawValue "color" is persisted in custom chips
        }
    }

    /// Append order — per BFL: subject (pose / expression / placement) first → style →
    /// context (environment) → lighting → camera/technical (framing / layout / angle /
    /// lens) LAST, so the user's subject stays front-loaded and technical modifiers
    /// don't crowd it out.
    static let appendOrder: [PromptPresetCategory] = [
        .pose, .expression, .placement,
        .style, .color,
        .environment, .lighting,
        .framing, .layout, .angle, .lens,
    ]

    /// Whether more than one chip can be active in this category. Categories describing a single
    /// physical fact (one pose, one expression, one framing, one lens, one location) are
    /// single-select — a new pick replaces the old one. Lighting, style, color and layout layer.
    var allowsMultiple: Bool {
        switch self {
        case .lighting, .style, .color, .layout: return true
        default:                                 return false
        }
    }
}

enum PromptPresets {
    /// Curated, verified vocab (BFL docs + skills repo + Klein-validated; 77 chips after
    /// the 2026-06 reform + studio pack — everything dropped returns in seconds via custom chips).
    /// Phrases are English — the known-good vocabulary is English and the model is
    /// English-caption-trained; the user can still type the subject in any language.
    /// Built-in + generated Library chips for a category (the Library 171 are appended).
    static func presets(for category: PromptPresetCategory) -> [PromptPreset] {
        builtinPresets(for: category) + PromptPresetLibrary.newChips(for: category)
    }

    static func builtinPresets(for category: PromptPresetCategory) -> [PromptPreset] {
        switch category {

        // ── SUBJECT ───────────────────────────────────────────────────────
        case .pose:
            return [
                .init(id: "pose.contrapposto", label: "contrapposto",         phrase: "standing in a contrapposto pose, weight shifted onto one leg"),
                .init(id: "pose.handhip",      label: "hand on hip",          phrase: "one hand resting on the hip"),
                .init(id: "pose.armscrossed",  label: "arms crossed",         phrase: "arms crossed, confident posture"),
                .init(id: "pose.leaning",      label: "leaning on wall",      phrase: "leaning casually against a wall"),
                .init(id: "pose.seated",       label: "seated",               phrase: "seated, poised and relaxed"),
                .init(id: "pose.walking",      label: "walking",              phrase: "walking, captured mid-stride"),
                .init(id: "pose.overshoulder", label: "glance over shoulder", phrase: "looking back over one shoulder at the camera"),
            ]
        case .expression:
            return [
                .init(id: "expr.neutral",     label: "neutral",      phrase: "a calm, neutral expression"),
                .init(id: "expr.softsmile",   label: "soft smile",   phrase: "a soft, gentle smile"),
                .init(id: "expr.laughing",    label: "laughing",     phrase: "laughing, a genuine joyful expression"),
                .init(id: "expr.serious",     label: "serious",      phrase: "a serious, intense expression"),
                .init(id: "expr.sultry",      label: "sultry gaze",  phrase: "a sultry, intense gaze into the camera"),
            ]
        case .placement:
            return [
                .init(id: "obj.flatlay",   label: "flat lay",      phrase: "arranged as a top-down flat lay"),
                .init(id: "obj.floating",  label: "floating",      phrase: "floating, levitating in mid-air"),
                .init(id: "obj.held",      label: "held in hand",  phrase: "held in hand, the hand framed out so the object dominates the shot"),
                .init(id: "obj.pedestal",  label: "on a pedestal", phrase: "displayed on a pedestal"),
                .init(id: "obj.grouped",   label: "grouped",       phrase: "several items arranged together in a neat composition"),
            ]

        // ── COMPOSITION ───────────────────────────────────────────────────
        case .framing:
            return [
                .init(id: "frame.xclose",  label: "extreme close-up", phrase: "extreme close-up, tightly cropped"),
                .init(id: "frame.closeup", label: "close-up",         phrase: "close-up shot, the subject filling most of the frame"),
                .init(id: "frame.half",    label: "half body",        phrase: "half-body shot, framed from the waist up"),
                .init(id: "frame.full",    label: "full body",        phrase: "full shot, the entire subject in frame head to toe"),
                .init(id: "frame.wide",    label: "wide / scene",     phrase: "wide environmental shot, subject small within the scene"),
            ]
        case .layout:
            return [
                .init(id: "frame.centered", label: "centered",       phrase: "perfectly centered, symmetrical composition"),
                .init(id: "frame.negspace", label: "negative space", phrase: "minimalist composition, vast empty negative space around the subject"),
            ]
        case .angle:
            return [
                .init(id: "angle.eye",          label: "eye level",     phrase: "photographed at eye level"),
                .init(id: "angle.low",          label: "low angle",     phrase: "photographed from a low angle, powerful and imposing"),
                .init(id: "angle.high",         label: "high angle",    phrase: "photographed from a high angle, looking down on the subject"),
                .init(id: "angle.over",         label: "overhead",      phrase: "overhead top-down view, shot straight from above"),
                .init(id: "angle.threequarter", label: "three-quarter", phrase: "three-quarter view, showing the front and side of the subject"),
                .init(id: "angle.rear",         label: "rear view",     phrase: "seen from behind, rear three-quarter view"),
                .init(id: "angle.aerial",       label: "aerial / drone",phrase: "high aerial view looking far down from above"),
            ]
        case .lens:
            return [
                .init(id: "lens.85mm",      label: "85mm portrait",  phrase: "shot on an 85mm f/1.4 lens, razor-thin depth of field, creamy bokeh"),
                .init(id: "lens.50mm",      label: "50mm natural",   phrase: "shot on a 50mm f/1.2 lens, natural perspective, shallow depth of field"),
                .init(id: "lens.24mm",      label: "24mm wide",      phrase: "shot on a 24mm wide-angle lens, expansive view, exaggerated perspective"),
                .init(id: "lens.macro",     label: "macro",          phrase: "extreme macro photograph, fine surface detail, very shallow focus plane"),
                .init(id: "lens.deep",      label: "deep focus",     phrase: "deep focus at f/8, everything sharp from front to back"),
                .init(id: "lens.medformat", label: "medium format",  phrase: "shot on a Hasselblad medium-format camera, ultra-fine detail"),
            ]

        // ── SCENE ─────────────────────────────────────────────────────────
        case .environment:
            return [
                .init(id: "env.studio",     label: "studio",          phrase: "in a photography studio against a clean white seamless backdrop"),
                .init(id: "env.forest",     label: "forest",          phrase: "in a lush green forest"),
                .init(id: "env.mountains",  label: "mountains",       phrase: "in a dramatic mountain landscape"),
                .init(id: "env.desert",     label: "desert",          phrase: "in a vast open desert"),
                .init(id: "env.street",     label: "urban street",    phrase: "on an urban city street"),
                .init(id: "env.neoncity",   label: "city at night",   phrase: "on a rain-slicked city street at night, glowing signs"),
                .init(id: "env.luxury",     label: "luxury interior", phrase: "in a luxurious modern interior"),
                .init(id: "env.industrial", label: "industrial",      phrase: "in an industrial warehouse space"),
                .init(id: "env.marble",     label: "marble surface",  phrase: "on a polished marble surface"),
                .init(id: "env.wood",       label: "wooden table",    phrase: "on a rustic wooden table"),
                .init(id: "env.colorseamless", label: "color seamless",    phrase: "against a vivid colored seamless paper backdrop in a photography studio"),
                .init(id: "env.gradient",      label: "gradient backdrop", phrase: "against a smooth gradient studio backdrop, softly brighter behind the subject and fading darker toward the edges"),
            ]
        case .lighting:
            return [
                .init(id: "light.golden",    label: "golden hour",  phrase: "warm golden-hour sunlight, soft and directional, casting long shadows"),
                .init(id: "light.blue",      label: "blue hour",    phrase: "cool blue-hour twilight, soft ambient light"),
                .init(id: "light.softbox",   label: "soft studio",  phrase: "soft, even, diffused light, gentle wraparound shading with no harsh shadows"),
                .init(id: "light.rim",       label: "rim light",    phrase: "rim lighting from behind, a glowing silhouette edge"),
                .init(id: "light.window",    label: "window light", phrase: "soft window light from one side, gentle falloff into shadow"),
                .init(id: "light.rembrandt", label: "Rembrandt",    phrase: "dramatic light from one side and slightly above, deep shadows on the far cheek with a small lit patch under the eye, sculpted dimensional portrait"),
                .init(id: "light.hardsun",   label: "hard sun",     phrase: "harsh direct sunlight, deep high-contrast shadows"),
                .init(id: "light.overcast",  label: "overcast",     phrase: "soft overcast daylight, even and almost shadowless"),
                .init(id: "light.neon",      label: "neon",         phrase: "moody neon lighting with colored reflections"),
                .init(id: "light.flash",     label: "direct flash", phrase: "direct on-camera flash, harsh bright light, 2000s snapshot feel"),
                .init(id: "light.lowkey",    label: "low-key",      phrase: "low-key lighting, dark and moody with deep shadows"),
                .init(id: "light.highkey",   label: "high-key",     phrase: "high-key lighting, bright and airy with minimal shadows"),
                .init(id: "light.clamshell",  label: "clamshell beauty", phrase: "soft even beauty light from straight in front, brightest on the face with a delicate shadow under the chin, flawless luminous skin"),
                .init(id: "light.threepoint", label: "3-point studio",   phrase: "balanced studio light, a bright main side, soft open shadows, a clean separating glow on the edges and crisp speculars"),
                .init(id: "light.gelled",     label: "gelled duo",       phrase: "saturated red light on one side and blue light on the other, bold color-split editorial lighting with a magenta blend where they meet"),
            ]

        // ── LOOK ──────────────────────────────────────────────────────────
        case .style:
            return [
                .init(id: "style.cinematic",   label: "cinematic",    phrase: "cinematic film still, dramatic movie lighting"),
                .init(id: "style.editorial",   label: "editorial",    phrase: "editorial fashion photography, polished and styled"),
                .init(id: "style.documentary", label: "documentary",  phrase: "documentary photography, candid and natural"),
                .init(id: "style.product",     label: "product / ad", phrase: "clean commercial product photography"),
                .init(id: "style.automotive",  label: "automotive",   phrase: "professional automotive photography, glossy paint reflections on bodywork"),
            ]
        case .color:
            return [
                .init(id: "color.warm",       label: "warm tones",    phrase: "warm color grading with golden tones"),
                .init(id: "color.cool",       label: "cool tones",    phrase: "cool color grading with blue tones"),
                .init(id: "color.tealorange", label: "teal & orange", phrase: "cinematic teal-and-orange color grade"),
                .init(id: "color.vibrant",    label: "vibrant",       phrase: "vibrant, saturated colors"),
                .init(id: "color.muted",      label: "muted",         phrase: "muted, desaturated color palette"),
                .init(id: "color.pastel",     label: "pastel",        phrase: "soft pastel color palette"),
                .init(id: "color.bw",         label: "black & white", phrase: "high-contrast black and white, deep blacks, bright highlights"),
                .init(id: "color.portra",     label: "Kodak Portra",  phrase: "shot on Kodak Portra 400 film, soft warm skin tones, fine grain"),
            ]
        }
    }

    /// LOOKS — one-tap bundles shown above the categories.
    static let bundles: [PresetBundle] = [
        .init(id: "look.cleanproduct", label: "Clean Product",
              chipIDs: ["style.product", "env.studio", "light.softbox", "lens.deep", "angle.threequarter"]),
        .init(id: "look.heroproduct", label: "Hero Product",
              chipIDs: ["style.product", "obj.pedestal", "light.lowkey", "light.rim", "lens.medformat"]),
        .init(id: "look.editorialfashion", label: "Editorial Fashion",
              chipIDs: ["style.editorial", "light.window", "frame.half", "lens.85mm", "color.muted"]),
        .init(id: "look.cinematicportrait", label: "Cinematic Portrait",
              chipIDs: ["style.cinematic", "light.window", "frame.closeup", "lens.85mm", "color.tealorange"]),
        .init(id: "look.filmportrait", label: "Film Portrait",
              chipIDs: ["color.portra", "light.golden", "frame.closeup", "lens.85mm"]),
        .init(id: "look.streetcandid", label: "Street Candid",
              chipIDs: ["style.documentary", "env.street", "light.overcast", "lens.50mm", "frame.full"]),
        .init(id: "look.automotivegolden", label: "Automotive Golden Hour",
              chipIDs: ["style.automotive", "env.mountains", "light.golden", "angle.low", "lens.24mm"]),
        .init(id: "look.neonnight", label: "Neon Night",
              chipIDs: ["style.cinematic", "env.neoncity", "light.neon", "lens.50mm"]),
        .init(id: "look.studioportrait", label: "Studio Portrait",
              chipIDs: ["env.studio", "light.threepoint", "frame.half", "lens.85mm"]),
        .init(id: "look.beautystudio", label: "Beauty Studio",
              chipIDs: ["env.studio", "light.clamshell", "frame.closeup", "lens.medformat"]),
        .init(id: "look.colorpop", label: "Color Pop",
              chipIDs: ["env.colorseamless", "light.gelled", "style.editorial", "frame.half"]),
    ] + PromptPresetLibrary.newBundles

    /// Physically contradictory MULTI-select chips (single-select axes already replace
    /// their siblings): picking one side deselects the other, so the prompt never says
    /// e.g. "harsh direct sunlight" and "soft overcast daylight" at once.
    static let conflicts: [String: Set<String>] = {
        let pairs: [(String, String)] = [
            ("light.lowkey", "light.highkey"),
            ("light.hardsun", "light.overcast"),
            ("light.hardsun", "light.softbox"),
            ("light.golden", "light.blue"),
            ("light.golden", "light.overcast"),
            ("light.flash", "light.softbox"),
            ("light.flash", "light.overcast"),
            ("light.rembrandt", "light.highkey"),
            ("light.clamshell", "light.hardsun"),
            ("light.clamshell", "light.flash"),
            ("light.threepoint", "light.hardsun"),
            ("light.gelled", "light.golden"),
            ("light.gelled", "color.bw"),
            ("light.gelled", "color.muted"),
            ("color.warm", "color.cool"),
            ("color.vibrant", "color.muted"),
            ("color.bw", "color.vibrant"),
            ("color.bw", "color.pastel"),
            ("color.bw", "color.tealorange"),
            ("color.bw", "color.warm"),
            ("color.bw", "color.cool"),
            ("color.bw", "color.portra"),
        ] + PromptPresetLibrary.newConflictPairs
        var map: [String: Set<String>] = [:]
        for (a, b) in pairs {
            map[a, default: []].insert(b)
            map[b, default: []].insert(a)
        }
        return map
    }()

    /// All presets flattened (for id → preset lookups).
    static let all: [PromptPreset] = PromptPresetCategory.allCases.flatMap { presets(for: $0) }

    /// The category that owns a given preset id (nil if unknown).
    static func category(for id: String) -> PromptPresetCategory? {
        PromptPresetCategory.allCases.first { category in
            presets(for: category).contains { $0.id == id }
        }
    }
    // NB: assembling selected phrases lives in `PresetCatalog.suffix(for:)` — it includes the
    // user's CUSTOM chips. A duplicate built-ins-only `suffix` here used to silently drop them.
}
