import SwiftUI

// ============================================================
//  Reusable indicator + control atoms (Dot, Sparkline, Ring,
//  Meter, chips, buttons, stepper, drop zone, flow layout).
// ============================================================

enum FxTone { case ok, amber, danger, idle }

/// Status dot with optional soft glow ring + gentle "breathing" when `live`
/// (opacity 1 → 0.35 → 1, ~2.6s ease-in-out — NOT a hard blink).
struct FxDot: View {
    var tone: FxTone = .ok
    var live: Bool = false
    var size: CGFloat = 8

    @State private var breathe = false

    private var color: Color {
        switch tone { case .ok: .fxOk; case .amber: .fxAccent; case .danger: .fxDanger; case .idle: .fxText3 }
    }
    private var glow: Color {
        switch tone { case .ok: .fxOkSoft; case .amber: .fxAccentSoft; case .danger: .fxDangerSoft; case .idle: .clear }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(tone == .idle ? 0.6 : (breathe ? 0.35 : 1))
            .background(Circle().fill(glow).frame(width: size + 6, height: size + 6))
            .onAppear { if live { startBreathing() } }
            .onChange(of: live) { _, on in on ? startBreathing() : stopBreathing() }
    }

    private func startBreathing() {
        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { breathe = true }
    }
    private func stopBreathing() {
        withAnimation(.easeInOut(duration: 0.25)) { breathe = false }
    }
}

/// Mini line chart with a soft gradient fill beneath the stroke.
struct Sparkline: View {
    var data: [Double]
    var color: Color = .fxAccent
    var fill: Bool = true
    var lineWidth: CGFloat = 1.6

    var body: some View {
        Canvas { ctx, size in
            guard data.count > 1 else { return }
            let minV = data.min() ?? 0
            let maxV = data.max() ?? 1
            let span = (maxV - minV) == 0 ? 1 : (maxV - minV)
            func pt(_ i: Int) -> CGPoint {
                let x = CGFloat(i) / CGFloat(data.count - 1) * size.width
                let y = size.height - 2 - CGFloat((data[i] - minV) / span) * (size.height - 4)
                return CGPoint(x: x, y: y)
            }
            var line = Path()
            line.move(to: pt(0))
            for i in 1..<data.count { line.addLine(to: pt(i)) }

            if fill {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.22), color.opacity(0)]),
                    startPoint: CGPoint(x: size.width / 2, y: 0),
                    endPoint: CGPoint(x: size.width / 2, y: size.height)))
            }
            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .drawingGroup(opaque: false)
    }
}

/// Circular progress ring (track + accent arc, rounded caps, starts at top).
struct Ring: View {
    var pct: Double          // 0…1
    var size: CGFloat = 66
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(Color.fxInset, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, pct)))
                .stroke(Color.fxAccent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: pct)
        }
        .frame(width: size, height: size)
    }
}

/// Horizontal progress meter (6pt). Amber by default, green via `ok`.
struct Meter: View {
    var value: Double        // 0…1
    var ok: Bool = false
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            Capsule(style: .continuous).fill(Color.fxInset)
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(
                            colors: ok ? [.fxOkDeep, .fxOk] : [.fxAccentDeep, .fxAccent],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, min(1, value)) * geo.size.width)
                }
        }
        .frame(height: height)
    }
}

/// Build tag — green status dot + mono `build x.y` (status bar, bottom-left).
struct BuildBadge: View {
    var version: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.fxGreen).frame(width: 6, height: 6)
            Text("VERSION \(version) BUILD \(AppVersion.build)").font(.fxMono(11)).foregroundStyle(Color.fxHdrMuted)
        }
    }
}

/// 15px section title (bold).
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.fx(15, weight: .bold)).foregroundStyle(Color.fxText).tracking(0.2)
    }
}

// ── Button styles ────────────────────────────────────────────────────────────

/// Primary amber-gradient button (dark text + inner top highlight).
struct FxPrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fx(13, weight: .semibold))
            .foregroundStyle(Color.fxOnAccent)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, 16)
            .background(
                LinearGradient(colors: [.fxAccent, .fxAccentDeep], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: FxRadius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FxRadius.button, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// Secondary button — inset surface + hairline, hover highlight.
struct FxSecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    var accentText: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, height: height, accentText: accentText, ghost: false)
    }
}

/// Ghost button — transparent until hover.
struct FxGhostButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    var accentText: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, height: height, accentText: accentText, ghost: true)
    }
}

private struct HoverBody: View {
    let configuration: ButtonStyle.Configuration
    var height: CGFloat
    var accentText: Bool
    var ghost: Bool
    @State private var hover = false
    var body: some View {
        configuration.label
            .font(.fx(13, weight: .semibold))
            .foregroundStyle(accentText ? Color.fxAccent : Color.fxText)
            .frame(height: height)
            .padding(.horizontal, 14)
            .background(
                (hover ? Color.fxHover : (ghost ? Color.clear : Color.fxInset)),
                in: RoundedRectangle(cornerRadius: FxRadius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FxRadius.button, style: .continuous)
                .strokeBorder(ghost ? Color.clear : Color.fxBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hover = $0 }
            .contentShape(Rectangle())
    }
}

/// 30×30 square icon button (inset, accent on hover).
struct FxIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var destructive: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        IconHover(configuration: configuration, size: size, destructive: destructive)
    }
    private struct IconHover: View {
        let configuration: ButtonStyle.Configuration
        var size: CGFloat
        var destructive: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 14))
                .foregroundStyle(hover ? (destructive ? Color.red : Color.fxAccent) : Color.fxText3)
                .frame(width: size, height: size)
                .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hover = $0 }
        }
    }
}

/// Custom "− [number] +" stepper with a label above.
struct FxStepper: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).fxLabel()
            HStack(spacing: 6) {
                pm("minus") { value = max(range.lowerBound, value - step) }
                Spacer(minLength: 0)
                Text(value.formatted(.number.grouping(.automatic)))
                    .font(.fxMono(12)).foregroundStyle(Color.fxText)
                    .frame(minWidth: 44)
                Spacer(minLength: 0)
                pm("plus") { value = min(range.upperBound, value + step) }
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .fxInsetField(radius: 8)
        }
    }

    private func pm(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.fxText3)
                .frame(width: 18, height: 18)
                .background(Color.fxHover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Drop zone (dashed border) — used for I2I reference and .safetensors import.
struct FxDropZone<Content: View>: View {
    var isTargeted: Bool = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(Color.fxInsetSoft, in: RoundedRectangle(cornerRadius: FxRadius.drop, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FxRadius.drop, style: .continuous)
                    .strokeBorder(isTargeted ? Color.fxAccent : Color.fxBorderStrong,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            )
    }
}

/// Simple left-to-right flow layout that wraps its subviews onto multiple rows — used for
/// preset chips in the narrow controls column.
struct FxFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(maxWidth, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.items.isEmpty && x + size.width > maxWidth {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.items.append(index)
            x += size.width + spacing
            current.width = max(current.width, x - spacing)
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
