import SwiftUI

// ============================================================
//  Typhoonminigen — Design tokens (direction «B · Telemetry»)
//  Dark-only, amber accent, no glass/material — solid colors.
// ============================================================

extension Color {
    /// Hex with optional alpha, sRGB. e.g. `Color(hex: 0xD8A06E)`.
    init(hex: UInt, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    // Surfaces
    static let fxBg          = Color(hex: 0x121317)   // window / content
    static let fxSidebar     = Color(hex: 0x141519)
    static let fxPanel       = Color(hex: 0x1B1D22)   // cards
    static let fxInset       = Color(hex: 0x131419)   // fields / recessed
    static let fxInsetSoft   = Color(hex: 0x181A1F)   // drop zones
    static let fxLogBg       = Color(hex: 0x0E0F11)   // log panel

    // Lines / hover
    static let fxHover        = Color.white.opacity(0.055)
    static let fxBorder       = Color.white.opacity(0.065)
    static let fxBorderStrong = Color.white.opacity(0.12)

    // Text
    static let fxText  = Color(hex: 0xECECED)
    static let fxText2 = Color(hex: 0xA4A6AD)
    static let fxText3 = Color(hex: 0x696C74)

    // Accent (amber)
    static let fxAccent     = Color(hex: 0xD8A06E)
    static let fxAccentDeep = Color(hex: 0xBB8350)
    static let fxAccentLine = Color(hex: 0xD8A06E, alpha: 0.45)
    static let fxAccentSoft = Color(hex: 0xD8A06E, alpha: 0.12)
    static let fxOnAccent   = Color(hex: 0x1C1308)   // dark text on accent buttons

    // Success (warm teal)
    static let fxOk     = Color(hex: 0x6FB9A0)
    static let fxOkSoft = Color(hex: 0x6FB9A0, alpha: 0.18)
    static let fxOkDeep = Color(hex: 0x3F7A55)       // green meter edge

    // Danger (critical thermal / memory pressure)
    static let fxDanger     = Color(hex: 0xE5685F)
    static let fxDangerSoft = Color(hex: 0xE5685F, alpha: 0.18)

    // Window chrome (header + status bar) — design_handoff_header_redesign,
    // variant «A · Clean base». Exact values from the handoff, used only by the bars.
    static let fxHdrBg        = Color(hex: 0x0D0F13)   // header / status bar surface
    static let fxHdrBorder    = Color(hex: 0x1A1E24)   // soft edge under/over the bars
    static let fxHdrText      = Color(hex: 0xE9E7E2)   // primary (current view, values)
    static let fxHdrMuted     = Color(hex: 0x8B919C)   // app name, build string
    static let fxHdrFaint     = Color(hex: 0x565D6B)   // separators, labels, idle icons
    static let fxHdrBtnBg     = Color(hex: 0x1B1F26)   // panel-toggle active/hover surface
    static let fxHdrBtnBorder = Color(hex: 0x23272E)
    static let fxEmber        = Color(hex: 0xDD9B5F)   // chip dot, logo gradient start
    static let fxEmberHi      = Color(hex: 0xEEBD8A)   // chip text, MLX stat value
    static let fxEmberDeep    = Color(hex: 0xB87840)   // logo gradient end
    static let fxEmberBg      = Color(hex: 0xDD9B5F, alpha: 0.13)
    static let fxEmberBorder  = Color(hex: 0xDD9B5F, alpha: 0.32)
    static let fxOnEmber      = Color(hex: 0x1A120A)   // logo letter
    static let fxGreen        = Color(hex: 0x5CC685)   // build status dot
}

extension Font {
    /// System SF at an explicit point size.
    static func fx(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// SF Mono — for data, numbers, logs, telemetry.
    static func fxMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum FxRadius {
    static let card: CGFloat   = 12
    static let field: CGFloat  = 9
    static let drop: CGFloat   = 10
    static let button: CGFloat = 9
    static let pill: CGFloat   = 7
}

extension View {
    /// Field/section label: 12 / medium / text3.
    func fxLabel() -> some View {
        font(.fx(12, weight: .medium)).foregroundStyle(Color.fxText3)
    }

    /// Card surface — panel bg, hairline border, soft elevation (direction B).
    func fxCard(padding: CGFloat = 14, radius: CGFloat = FxRadius.card, shadow: Bool = true) -> some View {
        self
            .padding(padding)
            .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
            .shadow(color: .black.opacity(shadow ? 0.32 : 0), radius: 10, x: 0, y: 6)
    }

    /// Inline capsule chip (inset bg + hairline). `accent` swaps to amber soft.
    func fxChip(accent: Bool = false, padV: CGFloat = 5, padH: CGFloat = 10, radius: CGFloat = 8) -> some View {
        self
            .padding(.vertical, padV).padding(.horizontal, padH)
            .background(accent ? Color.fxAccentSoft : Color.fxInset, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(accent ? Color.fxAccentLine : Color.fxBorder, lineWidth: 1))
    }

    /// "ok" pill — teal text on teal-soft, used for compatibility / loaded badges.
    func fxPillOk() -> some View {
        font(.fxMono(11))
            .foregroundStyle(Color.fxOk)
            .padding(.vertical, 4).padding(.horizontal, 9)
            .background(Color.fxOkSoft, in: RoundedRectangle(cornerRadius: FxRadius.pill, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FxRadius.pill, style: .continuous).strokeBorder(Color.fxOkSoft, lineWidth: 1))
    }

    /// Recessed input surface (inset bg + border + radius).
    func fxInsetField(radius: CGFloat = FxRadius.field) -> some View {
        background(Color.fxInset, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
    }
}
