import SwiftUI

/// Side-by-side tier matrix so the model choice is an informed one. All RAM/speed figures
/// are the app's OWN phys_footprint measurements on a base M4 32 GB, 2026-06-10 (not the
/// engine's Dev-sized estimates, which overstate Klein by ~10 GB). 4B: steady ~6.2 GB
/// through load+denoise, ~11–13 GB for 2–4 s at the final VAE decode (upper bound — a
/// 16 GB Mac gets stricter engine presets than the 32 GB test machine did).
struct TierComparisonCard: View {
    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        let k4: String
        let k9: String
    }

    private static let rows: [Row] = [
        Row(label: "Disk (transformer + encoder)", k4: "~4 + 4 GB", k9: "~18 + 8 GB"),
        Row(label: "RAM while generating", k4: "~6 GB · brief ~12 GB spike", k9: "~19–20 GB"),
        Row(label: "Comfortable on", k4: "16 GB Macs", k9: "32 GB Macs"),
        Row(label: "HuggingFace token", k4: "not needed", k9: "required (gated)"),
        Row(label: "License", k4: "Apache 2.0", k9: "FLUX Non-Commercial"),
        Row(label: "LoRA adapters", k4: "dim 3072 only", k9: "dim 4096 only"),
        Row(label: "References (I2I)", k4: "up to 3", k9: "up to 3"),
        Row(label: "Speed / quality", k4: "~1 min per 1024² image", k9: "~2¼ min, best quality"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHICH MODEL?")
                .font(.fx(11, weight: .semibold)).tracking(0.5)
                .foregroundStyle(Color.fxText3)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("")
                    Text("Klein 4B").font(.fxMono(11.5)).foregroundStyle(Color.fxAccent)
                    Text("Klein 9B").font(.fxMono(11.5)).foregroundStyle(Color.fxAccent)
                }
                ForEach(Self.rows) { row in
                    GridRow {
                        Text(row.label).font(.fx(11.5)).foregroundStyle(Color.fxText3)
                        Text(row.k4).font(.fxMono(11)).foregroundStyle(Color.fxText2)
                        Text(row.k9).font(.fxMono(11)).foregroundStyle(Color.fxText2)
                    }
                }
            }
            Text("LoRA adapters are NOT interchangeable between tiers — a 9B adapter won't load on 4B and vice versa.")
                .font(.fx(10.5)).foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)   // match the screen's text measure
        .fxCard()
    }
}
