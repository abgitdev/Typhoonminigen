import SwiftUI

struct SystemView: View {
    @Bindable var vm: SystemViewModel
    let stats: SessionStats

    @State private var updateCheckEnabled = UpdateService.isEnabled
    @State private var confirmRemoveAll = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                let s = vm.telemetry.snapshot
                LazyVGrid(columns: columns, spacing: 12) {
                    SysStat(icon: "cpu", name: "CPU",
                            big: "\(Int(s.cpuPercent.rounded()))%",
                            sub: "\(s.cpuCoreCount) cores",
                            spark: vm.telemetry.cpuHistory, sparkColor: .fxAccent)
                        .help("Processor load right now — the sparkline shows recent history.")
                    SysStat(icon: "memorychip", name: "App memory",
                            big: ByteFormat.string(s.appFootprintBytes),
                            sub: "of \(ByteFormat.string(s.systemTotalBytes))",
                            spark: vm.telemetry.appMemHistory, sparkColor: .fxOk,
                            meter: fraction(Double(s.appFootprintBytes), Double(s.systemTotalBytes)), meterOk: true)
                        .help("RAM this app holds right now, out of total installed. A brief spike at the end of each render is normal.")
                    SysStat(icon: "cpu.fill", name: "GPU",
                            big: s.gpuName,
                            sub: s.gpuCoreCount > 0 ? "\(s.gpuCoreCount) cores · Metal" : "Metal",
                            spark: vm.telemetry.gpuHistory, sparkColor: .fxAccent,
                            liveDot: true)
                        .help("The Apple GPU that renders images via Metal — utilization history in the sparkline.")
                    SysStat(icon: "bolt.fill", name: "MLX active",
                            big: ByteFormat.string(s.mlxActiveBytes),
                            sub: "peak \(ByteFormat.string(s.mlxPeakBytes)) · cache \(ByteFormat.string(s.mlxCacheBytes))",
                            spark: vm.telemetry.mlxHistory, sparkColor: .fxAccent)
                        .help("GPU memory MLX holds in tensors now. Peak = session high; cache = reusable buffer pool that \u{201C}Clear cache\u{201D} empties.")
                }

                SysStat(icon: "externaldrive", name: "Disk free",
                        big: ByteFormat.string(s.diskFreeBytes),
                        sub: "of \(ByteFormat.string(s.diskTotalBytes))",
                        meter: fraction(Double(s.diskTotalBytes - s.diskFreeBytes), Double(s.diskTotalBytes)),
                        meterOk: false, wide: true)
                    .help("Free disk space — Klein 4B needs ~8 GB on disk, Klein 9B ~26 GB.")

                maintenance
                updateCheckRow
                logsPanel
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.fxBg)
        .task { vm.onAppear() }
        .onDisappear { vm.onDisappear() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SectionTitle(text: "System")
            Text("\(vm.telemetry.snapshot.gpuName) · \(osVersion)")
                .font(.fx(12)).foregroundStyle(Color.fxText3)
            Spacer()
            // Session stats lived in the bottom status bar until the header redesign
            // made that bar uniform telemetry — this is their home now.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 7) {
                    FxDot(tone: .ok, live: true)
                    Text("uptime \(stats.uptimeString(now: ctx.date)) · generations \(stats.generationCount)")
                }
                .font(.fxMono(11)).foregroundStyle(Color.fxText3)
            }
            .help("This session only — time since launch and renders completed. Resets when the app quits.")
        }
    }

    private var maintenance: some View {
        HStack(spacing: 10) {
            Text("MAINTENANCE").font(.fx(11, weight: .semibold)).tracking(0.5).foregroundStyle(Color.fxText3)
            Spacer()
            Button("Unload model") { vm.freeMemory() }.buttonStyle(FxSecondaryButtonStyle(height: 32))
                .help("Free the model from RAM — it stays on disk and reloads on the next render (~50 s extra).")
            Button("Clear cache") { vm.clearCaches() }.buttonStyle(FxSecondaryButtonStyle(height: 32))
                .help("Delete gallery thumbnails and the MLX buffer pool — both rebuild on demand")
            Button("Clear logs") { vm.clearLogs() }.buttonStyle(FxSecondaryButtonStyle(height: 32))
                .help("Empty the app's log file")
            Button("Remove all data…") { confirmRemoveAll = true }
                .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                .help("Delete EVERYTHING this app stored — models, encoders, the HuggingFace cache, your gallery images, LoRAs, presets and logs. Use this BEFORE dragging the app to the Trash so nothing is left behind.")
                .confirmationDialog("Remove all models & data?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
                    Button("Remove everything", role: .destructive) { vm.removeAllData() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Permanently deletes all downloaded models + encoders, the HuggingFace cache, every image in your gallery, your LoRAs, presets and logs — no Trash. Do this right before deleting the app. The app itself stays until you trash it.")
                }
        }
        .padding(.top, 2)
        .overlay(alignment: .bottomLeading) {
            if let msg = vm.lastAction {
                Text(msg.text).font(.fx(11))
                    .foregroundStyle(msg.isError ? Color.fxDanger : Color.fxText3)
                    .offset(y: 20)
            }
        }
    }

    // .padding(.top, 14) keeps clear of the maintenance lastAction message (overlay, y+20).
    private var updateCheckRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                updateCheckEnabled.toggle()
                UpdateService.setEnabled(updateCheckEnabled)
            } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(updateCheckEnabled ? Color.fxAccent : Color.fxInset)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(updateCheckEnabled ? Color.fxAccent : Color.fxBorderStrong, lineWidth: 1))
                        .overlay {
                            if updateCheckEnabled {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.fxOnAccent)
                            }
                        }
                        .frame(width: 16, height: 16)
                    Text("Check for updates on launch")
                        .font(.fx(12.5)).foregroundColor(.fxText2)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Off by default. When on, the app asks GitHub on launch (at most once an hour) whether a newer release exists; a found update shows as a pill in the header. No account, no tracking — turn it off any time.")
            Text("Asks api.github.com for the latest release on launch — nothing else is sent, at most once an hour.")
                .font(.fx(11)).foregroundStyle(Color.fxText3)
                .padding(.leading, 25)
        }
        .padding(.top, 14)
    }

    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FxDot(tone: .amber, live: true, size: 7)
                Text("Logs").font(.fx(11)).foregroundStyle(Color.fxText3)
                Spacer()
                Text("last \(min(vm.logLines.count, 12))").font(.fxMono(11)).foregroundStyle(Color.fxText3)
            }
            .help("Newest 12 entries of the app's log file, latest first — \u{201C}Clear logs\u{201D} above empties the file.")
            if vm.logLines.isEmpty {
                Text("No logs yet.").font(.fxMono(11)).foregroundStyle(Color.fxText3)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(vm.logLines.prefix(12).enumerated()), id: \.offset) { idx, line in
                        HStack(spacing: 8) {
                            Text(line)
                                .font(.fxMono(11))
                                .foregroundStyle(logColor(line))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if idx == 0 {
                                Text("now").font(.fxMono(9.5)).foregroundStyle(Color.fxText3)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fxLogBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        .padding(.top, 14)
    }

    private func logColor(_ line: String) -> Color {
        if line.localizedCaseInsensitiveContains("error") || line.localizedCaseInsensitiveContains("failed") { return .red }
        if line.localizedCaseInsensitiveContains("done") { return .fxOk }
        return .fxText2
    }

    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let names = [26: "Tahoe", 15: "Sequoia", 14: "Sonoma"]
        let base = v.minorVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion)" : "macOS \(v.majorVersion)"
        if let name = names[v.majorVersion] { return "\(base) \(name)" }
        return base
    }

    private func fraction(_ part: Double, _ whole: Double) -> Double {
        whole > 0 ? max(0, min(1, part / whole)) : 0
    }
}

private struct SysStat: View {
    let icon: String
    let name: String
    let big: String
    let sub: String
    var spark: [Double]? = nil
    var sparkColor: Color = .fxAccent
    var meter: Double? = nil
    var meterOk: Bool = false
    var liveDot: Bool = false
    var wide: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Color.fxText3)
                Text(name).font(.fx(11.5)).foregroundStyle(Color.fxText3).lineLimit(1)
                Spacer(minLength: 0)
                if liveDot { FxDot(tone: .ok, live: true, size: 7) }
            }
            Text(big).font(.fxMono(21, weight: .bold)).foregroundStyle(Color.fxText)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let spark { Sparkline(data: spark, color: sparkColor).frame(height: 28) }
            if let meter { Meter(value: meter, ok: meterOk) }
            Spacer(minLength: 4)
            Text(sub).font(.fxMono(11)).foregroundStyle(Color.fxText3).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13).padding(.horizontal, 14)
        .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 10, x: 0, y: 6)
    }
}
