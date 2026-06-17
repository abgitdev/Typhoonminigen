import SwiftUI

// ============================================================
//  Window chrome: custom 48px header, 216px sidebar, 28px
//  bottom status bar (design_handoff_header_redesign, «A · Clean
//  base»). Real macOS traffic lights are kept via
//  .windowStyle(.hiddenTitleBar) — we only inset for them.
// ============================================================

/// 28×28 header icon button for panel toggles. Active = lit surface + bright
/// glyph; inactive = faint glyph, surface only on hover.
struct FxPanelToggle: View {
    let icon: String
    let active: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.fxHdrText : Color.fxHdrFaint)
                .frame(width: 28, height: 28)
                .background((active || hover) ? Color.fxHdrBtnBg : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(active ? Color.fxHdrBtnBorder : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// 20×20 gradient logo mark — shown in the header only while the sidebar is
/// collapsed, so app identity is never lost.
struct FxLogoMark: View {
    var body: some View {
        Text("T")
            .font(.fx(11, weight: .bold))
            .foregroundStyle(Color.fxOnEmber)
            .frame(width: 20, height: 20)
            .background(
                LinearGradient(colors: [.fxEmber, .fxEmberDeep],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Read-only model status chip (header, right group): glowing ember dot,
/// model name, dimmed state suffix ("on disk" / "in memory" / "not downloaded").
struct FxModelChip: View {
    let name: String
    let state: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.fxEmber)
                .frame(width: 6, height: 6)
                .shadow(color: .fxEmber, radius: 3)
            Text(name).foregroundStyle(Color.fxEmberHi)
            Text("· \(state)").foregroundStyle(Color.fxEmberHi.opacity(0.55))
        }
        .font(.fxMono(11.5))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.fxEmberBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.fxEmberBorder, lineWidth: 1))
    }
}

/// Update-available pill (header, right group): appears only when a newer
/// GitHub release was found; click opens the release page.
struct FxUpdatePill: View {
    let version: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.fxEmber)
                Text("update \(version)").foregroundStyle(Color.fxEmberHi)
            }
            .font(.fxMono(11.5))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.fxEmberBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.fxEmberBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Version \(version) is available — click to open the release page. Right-click to skip this version.")
    }
}

/// Top chrome bar («A · Clean base»). Leaves room for the real traffic lights,
/// then the sidebar toggle, logo mark while the sidebar is collapsed, and the
/// "Typhoonminigen / <view>" breadcrumb. Center stays empty; caller supplies
/// the right group (live progress, model chip, rail toggle).
struct FxTitleBar<Trailing: View>: View {
    let section: String
    @Binding var sidebarVisible: Bool
    @ViewBuilder var trailing: () -> Trailing

    // Trailing edge of the real traffic lights — queried from the window because
    // their position varies across macOS versions and was leaving a dead gap
    // before the left group with a hardcoded inset. 0 = lights hidden (fullscreen).
    @State private var lightsMaxX: CGFloat = 58

    var body: some View {
        HStack(spacing: 10) {
            FxPanelToggle(icon: "sidebar.left", active: sidebarVisible, help: "Toggle sidebar") {
                withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible.toggle() }
            }
            if !sidebarVisible {
                FxLogoMark().transition(.opacity)
            }
            HStack(spacing: 8) {
                Text("Typhoonminigen").font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxHdrMuted)
                Text("/").font(.fx(12)).foregroundStyle(Color.fxHdrFaint)
                Text(section).font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxHdrText)
            }

            Spacer()

            HStack(spacing: 8) { trailing() }
        }
        .padding(.leading, max(12, lightsMaxX + 10))   // fullscreen (0) → edge-hug like the right side
        .padding(.trailing, 12)
        .frame(height: 48)
        .background(Color.fxHdrBg)
        .background(TrafficLightsInsetReader(maxX: $lightsMaxX))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.fxHdrBorder).frame(height: 1) }
    }
}

/// Reports where the window's traffic lights actually end (window coordinates),
/// so the header's left group can hug them instead of guessing an inset.
/// Reports 0 while the window is fullscreen — the lights are hidden there.
private struct TrafficLightsInsetReader: NSViewRepresentable {
    @Binding var maxX: CGFloat

    func makeNSView(context: Context) -> LightsProbeView {
        let v = LightsProbeView()
        v.onChange = { x in
            DispatchQueue.main.async {
                if abs(maxX - x) > 0.5 {
                    AppLog.info("Header: traffic-light inset measured \(Int(x))pt")
                    maxX = x
                }
            }
        }
        return v
    }
    func updateNSView(_ nsView: LightsProbeView, context: Context) {}

    final class LightsProbeView: NSView {
        var onChange: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let w = window {
                // The lights disappear/reappear with fullscreen — re-measure on both.
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowStateChanged),
                    name: NSWindow.didEnterFullScreenNotification, object: w)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowStateChanged),
                    name: NSWindow.didExitFullScreenNotification, object: w)
            }
            report()
        }
        override func layout() {
            super.layout()
            report()
        }
        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func windowStateChanged() { report() }

        private func report() {
            guard let w = window else { return }
            if w.styleMask.contains(.fullScreen) {
                onChange?(0)
                return
            }
            guard let zoom = w.standardWindowButton(.zoomButton),
                  let bar = zoom.superview else { return }
            onChange?(bar.convert(zoom.frame, to: nil).maxX)
        }
    }
}

/// Left navigation rail.
struct FxSidebar: View {
    @Binding var section: AppSection
    /// Optional trailing accessory per item (live dot / count / cpu%).
    let tail: (AppSection) -> AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text("T")
                    .font(.fx(13, weight: .heavy))
                    .foregroundStyle(Color.fxOnAccent)
                    .frame(width: 24, height: 24)
                    .background(
                        LinearGradient(colors: [.fxAccent, .fxAccentDeep],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Typhoonminigen").font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText)
                    Text("FLUX.2 Klein · MLX").font(.fx(10, weight: .medium)).foregroundStyle(Color.fxText3)
                }
            }
            .padding(.top, 6).padding(.horizontal, 8).padding(.bottom, 12)

            Text("WORKSPACE")
                .font(.fx(10.5, weight: .semibold)).tracking(0.7)
                .foregroundStyle(Color.fxText3)
                .padding(.top, 10).padding(.horizontal, 9).padding(.bottom, 5)

            VStack(spacing: 2) {
                ForEach(AppSection.allCases) { item in
                    NavItem(item: item, isActive: section == item, tail: tail(item)) {
                        section = item
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(width: 216)
        .background(Color.fxSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.fxBorder).frame(width: 1) }
    }
}

private struct NavItem: View {
    let item: AppSection
    let isActive: Bool
    let tail: AnyView?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 15))
                    .frame(width: 16)
                    .foregroundStyle(isActive ? Color.fxAccent : Color.fxText2)
                    .opacity(isActive ? 1 : 0.85)
                Text(item.title)
                    .font(.fx(13))
                    .foregroundStyle(isActive ? Color.fxText : Color.fxText2)
                Spacer(minLength: 0)
                if let tail { tail }
            }
            .padding(.vertical, 7).padding(.horizontal, 9)
            .background(
                isActive ? Color.fxAccentSoft : (hover ? Color.fxHover : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                if isActive {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.fxAccent)
                        .frame(width: 3, height: 18)
                        .offset(x: -10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.help)
    }
}

/// Bottom status bar — build tag on the left, live telemetry stats on the
/// right (same on every view; telemetry lives here permanently, not in the header).
struct FxStatusBar<Trailing: View>: View {
    let version: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            BuildBadge(version: version)
            Spacer()
            HStack(spacing: 14) { trailing() }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Color.fxHdrBg)
        .overlay(alignment: .top) { Rectangle().fill(Color.fxHdrBorder).frame(height: 1) }
    }
}

/// One status-bar telemetry stat: faint label + value. `accent` renders the
/// value in ember — reserved for the signature MLX stat.
struct FxStat: View {
    let label: String
    let value: String
    var accent: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(Color.fxHdrFaint)
            Text(value).foregroundStyle(accent ? Color.fxEmberHi : Color.fxHdrText)
        }
        .font(.fxMono(11))
        .lineLimit(1)
    }
}

/// Thin vertical divider between status items.
struct StatusSep: View {
    var body: some View { Rectangle().fill(Color.fxBorder).frame(width: 1, height: 14) }
}
