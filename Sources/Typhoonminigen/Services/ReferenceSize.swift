import Foundation

/// Converts a reference image's pixel size into a SAFE generation size.
///
/// Keeps the reference's aspect ratio but normalizes the OUTPUT to Klein's native training
/// area (~1024² ≈ 1.05 MP): beyond ~1 MP the 4-step distilled model starts producing
/// anatomy mutations (extra fingers, warped limbs — user-observed at 1536×1040), and below
/// it detail is wasted. Sides stay within 512–1536 and round to /32 (the engine builds its
/// output CGImage with a 24-bit width×3 row stride that CoreGraphics 32-aligns — a width that
/// isn't /32 makes every scanline read off-by-N → a clean horizontal tear, e.g. 720×1280).
/// Pure function so the audit harness can test it. The engine must never receive raw photo
/// dimensions: output latents scale quadratically and the engine's own size guard is dead
/// code — a native 12 MP iPhone photo would swap-freeze a 32 GB Mac.
enum ReferenceSize {
    static let minSide = 512
    static let maxSide = 1536
    static let targetArea = 1024 * 1024   // Klein's quality sweet spot
    /// Generation sides MUST be multiples of this. The engine's VAE→CGImage uses a 24-bit
    /// (width×3) row stride that CoreGraphics aligns to 32 bytes; a /16-but-not-/32 width (720)
    /// makes each scanline read off-by-16 → a horizontal tear. /32 width keeps width×3 aligned
    /// (3 is coprime to 32). Snapping BOTH dims to /32 is the simple blanket guarantee.
    static let grain = 32

    /// Round to the nearest /32, clamped to [minSide, maxSide]. For hand/restored values.
    static func snap(_ v: Int) -> Int {
        min(maxSide, max(minSide, Int((Double(v) / Double(grain)).rounded()) * grain))
    }

    /// Floor to /32, clamped — for the RAM-area cap, which must stay ≤ the cap (never round up).
    static func snapDown(_ v: Int) -> Int {
        min(maxSide, max(minSide, (v / grain) * grain))
    }

    /// nil only for degenerate (non-positive) input.
    static func snapped(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        var w = Double(width), h = Double(height)
        // Normalize to the target AREA (up or down), keeping the aspect ratio…
        let areaScale = (Double(targetArea) / (w * h)).squareRoot()
        w *= areaScale
        h *= areaScale
        // …cap the long side (extreme panoramas)…
        let down = min(1.0, Double(maxSide) / max(w, h))
        w *= down
        h *= down
        // …and raise the short side to the floor. The cap wins over the ratio for
        // extreme aspects (an 8:1 panorama becomes 1536×512 — bounded beats faithful).
        let up = max(1.0, Double(minSide) / min(w, h))
        w = min(Double(maxSide), w * up)
        h = min(Double(maxSide), h * up)
        let rw = snap(Int(w.rounded()))
        let rh = snap(Int(h.rounded()))
        return (rw, rh)
    }
}
