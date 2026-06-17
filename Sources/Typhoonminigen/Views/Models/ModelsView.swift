import SwiftUI

struct ModelsView: View {
    @Bindable var vm: ModelsViewModel
    @State private var editingToken = false
    @State private var confirmClearHF = false

    var body: some View {
        VStack(spacing: 0) {
            // Pinned banner: guard refusals / confirmations used to render at the very bottom
            // of this long ScrollView, below the fold and invisible. Keep them always on screen.
            if let msg = vm.lastAction {
                Text(msg.text).font(.fx(11))
                    .foregroundStyle(msg.isError ? Color.fxDanger : Color.fxText2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(msg.isError ? Color.fxDanger.opacity(0.12) : Color.fxInset)
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SectionTitle(text: "Models")
                    Spacer()
                    // Reads the SAVED state, not the text field — typing used to flip this
                    // to "connected" before the token was ever persisted.
                    HStack(spacing: 7) {
                        FxDot(tone: vm.tokenSaved ? .ok : .idle, live: vm.tokenSaved)
                        Text(vm.tokenSaved ? "HuggingFace · token saved" : "HuggingFace · no token")
                    }
                    .font(.fxMono(11)).foregroundStyle(Color.fxText3)
                    .help("Shows whether a HuggingFace token is saved in the Keychain. Only the gated Klein 9B needs one — 4B and all components download without it.")
                }

                Text("Klein 9B is a gated model — downloading it needs a HuggingFace access token (stored in the Keychain, it never leaves your Mac). Klein 4B and every component below download without a token.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.top, 8).padding(.bottom, 18)

                tokenCard

                TierComparisonCard()
                    .padding(.top, 14)

                HStack {
                    Text("INSTALLED").font(.fx(11, weight: .semibold)).tracking(0.5).foregroundStyle(Color.fxText3)
                    Spacer()
                    importButton
                    Text(installedSummary).font(.fxMono(11)).foregroundStyle(Color.fxText3)
                }
                .padding(.top, 18).padding(.bottom, 12)

                ForEach(vm.models) { model in
                    ModelRow(model: model, vm: vm)
                }

                if !vm.auxComponents.isEmpty {
                    HStack {
                        Text("COMPONENTS").font(.fx(11, weight: .semibold)).tracking(0.5).foregroundStyle(Color.fxText3)
                        Spacer()
                        Text(componentsSummary).font(.fxMono(11)).foregroundStyle(Color.fxText3)
                    }
                    .padding(.top, 14).padding(.bottom, 4)
                    Text("Downloaded alongside the model — \u{201C}Delete\u{201D} on the model row frees only the transformer; this is the rest. Everything here re-downloads automatically when needed.")
                        .font(.fx(11.5)).foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 620, alignment: .leading)
                        .padding(.bottom, 12)
                    ForEach(vm.auxComponents) { comp in
                        AuxComponentRow(comp: comp, vm: vm)
                    }
                }

                storageCard
                    .padding(.top, 18)

            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.fxBg)
        .task { vm.reload() }
    }

    private var importButton: some View {
        Button(vm.importing ? "Importing…" : "Import existing weights…") {
            vm.pickAndScanImportFolder()
        }
        .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
        .disabled(vm.importing || vm.downloadingTier != nil)
        .help("Use MLX-format weights you already have on disk — pick the folder that contains them. ComfyUI .safetensors checkpoints are not supported.")
        .confirmationDialog(
            "Import found components?",
            isPresented: Binding(
                get: { vm.pendingImport != nil },
                set: { if !$0 { vm.pendingImport = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Copy (uses disk, safe)") { vm.performImport(mode: .copy) }
            Button("Link (saves disk — original must stay in place)") { vm.performImport(mode: .link) }
            Button("Cancel", role: .cancel) { vm.cancelImport() }
        } message: {
            Text(importDialogMessage)
        }
    }

    private var importDialogMessage: String {
        let items = vm.pendingImport ?? []
        let lines = items.map { item in
            let size = ByteFormat.string(item.sizeBytes)
            return item.alreadyInstalled
                ? "\(item.component.displayName) — \(size) — already installed, will be skipped"
                : "\(item.component.displayName) — \(size)"
        }
        return lines.joined(separator: "\n")
            + "\n\nCopy duplicates the files into the app's models folder (instant clone on the same disk). Link points at the originals instead — if they move or their drive is unmounted, the model stops loading."
    }

    private var installedSummary: String {
        let installed = vm.models.filter { $0.isDownloaded }
        let bytes = installed.reduce(Int64(0)) { $0 + $1.downloadedBytes }
        let word = installed.count == 1 ? "model" : "models"
        return "\(installed.count) \(word) · \(ByteFormat.string(bytes))"
    }

    private var componentsSummary: String {
        let bytes = vm.auxComponents.reduce(Int64(0)) { $0 + $1.bytes }
        return "\(vm.auxComponents.count) on disk · \(ByteFormat.string(bytes))"
    }

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                (Text("HuggingFace token ").foregroundColor(.fxText2)
                 + Text("(Klein 9B only)").foregroundColor(.fxText3))
                    .font(.fx(12, weight: .medium))
                Spacer()
                if vm.tokenSaved {
                    HStack(spacing: 6) { FxDot(tone: .ok, size: 7); Text("saved") }.fxPillOk()
                }
            }
            HStack(spacing: 10) {
                if vm.tokenSaved && !editingToken {
                    Text(String(repeating: "•", count: 28))
                        .font(.fxMono(13)).tracking(2).foregroundStyle(Color.fxText2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit") { editingToken = true }
                        .buttonStyle(FxGhostButtonStyle(height: 28, accentText: true))
                        .help("Replace or clear the saved token")
                } else {
                    SecureField("hf_…", text: $vm.hfToken)
                        .textFieldStyle(.plain)
                        .font(.fxMono(12)).foregroundStyle(Color.fxText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("Paste a HuggingFace \u{201C}Read\u{201D} token (starts with hf_) — required only to download the gated Klein 9B. Saved to the macOS Keychain when you press Save.")
                    Button("Save") {
                        vm.persistToken()
                        editingToken = false
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 28, accentText: true))
                    .help("Store the token in the macOS Keychain — it never leaves this Mac. Saving an empty field removes the stored token.")
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .fxInsetField(radius: 10)
            // First-launch path: both steps happen on huggingface.co, once.
            HStack(spacing: 16) {
                Link("Get a token ↗", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                    .help("Opens huggingface.co — create a free account, then a \u{201C}Read\u{201D} token")
                Link("Accept the Klein 9B license ↗", destination: URL(string: "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B")!)
                    .help("Opens the model page — accept the license there or the gated download is refused")
                Spacer()
            }
            .font(.fx(11)).tint(Color.fxAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard()
    }

    private var storageCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HuggingFace cache").font(.fx(12.5, weight: .semibold)).foregroundStyle(Color.fxText)
                Text("Some model weights are cached here separately — deleting a model above doesn't free this.")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(vm.hfCacheBytes)).font(.fxMono(12)).foregroundStyle(Color.fxText2)
            Button("Clear") { confirmClearHF = true }
                .buttonStyle(FxSecondaryButtonStyle(height: 28, accentText: true))
                .disabled(vm.hfCacheBytes == 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        .confirmationDialog("Clear the HuggingFace cache?", isPresented: $confirmClearHF, titleVisibility: .visible) {
            Button("Clear (\(ByteFormat.string(vm.hfCacheBytes)))", role: .destructive) { vm.clearHFCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(ByteFormat.string(vm.hfCacheBytes)) of re-downloadable model files. This is a shared cache — other HuggingFace tools on this Mac use it too.")
        }
    }
}

private struct ModelRow: View {
    let model: ModelInfo
    @Bindable var vm: ModelsViewModel
    @State private var confirmDelete = false

    private var isDownloading: Bool { vm.downloadingTier == model.tier }

    var body: some View {
        HStack(spacing: 14) {
            tile
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text(model.title).font(.fx(13.5, weight: .semibold)).foregroundStyle(Color.fxText)
                    if model.isDownloaded && vm.loadedTier == model.tier {
                        HStack(spacing: 6) { FxDot(tone: .ok, live: true, size: 7); Text("loaded in memory") }.fxPillOk()
                    } else if model.isDownloaded {
                        HStack(spacing: 6) { FxDot(tone: .ok, size: 7); Text("on disk") }.fxPillOk()
                    }
                }
                if isDownloading {
                    HStack(spacing: 8) {
                        // Always-animating spinner = clearly alive even when the % can't move (the
                        // transformer arrives as one big file, so the bar only jumps at file/shard
                        // boundaries). The spinner shows it's still working — not frozen.
                        ProgressView().controlSize(.small)
                        Meter(value: vm.downloadProgress).frame(width: 200)
                            .animation(.easeInOut(duration: 0.3), value: vm.downloadProgress)
                    }
                    Text(vm.downloadMessage).font(.fxMono(10.5)).foregroundStyle(Color.fxText3).lineLimit(1)
                    if model.tier == .klein4B {
                        Text("the bar jumps forward as each part finishes — the spinner shows it's still downloading")
                            .font(.fx(10.5)).foregroundStyle(Color.fxText3)
                    }
                } else {
                    HStack(spacing: 8) {
                        tag("hybrid")
                        tag("~\(model.estimatedSizeGB) GB")
                        tag(model.license)
                        if model.isGated { tag("gated") }
                    }
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 10, x: 0, y: 6)
        .padding(.bottom, 12)
    }

    private var tile: some View {
        Image(systemName: "cube")
            .font(.system(size: 20))
            .foregroundStyle(Color.fxAccent)
            .frame(width: 42, height: 42)
            .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.fxAccentLine, lineWidth: 1))
    }

    @ViewBuilder private var controls: some View {
        if isDownloading {
            HStack(spacing: 10) {
                Text("\(Int(vm.downloadProgress * 100))%").font(.fxMono(12)).foregroundStyle(Color.fxText2)
                Button("Cancel") { vm.cancelDownload() }
                    .buttonStyle(FxGhostButtonStyle(height: 28, accentText: true))
                    .help("Stop the download — already-fetched files are reused next time")
            }
        } else if model.isDownloaded {
            HStack(spacing: 10) {
                if !model.isEncoderDownloaded {
                    // Recovery path: transformer on disk but the encoder phase was
                    // cancelled/failed — without it generation can't start.
                    Button("Get encoder") { vm.downloadEncoder(model.tier) }
                        .buttonStyle(FxPrimaryButtonStyle(height: 30))
                        .disabled(vm.downloadingTier != nil || vm.importing)
                        .help("The tier's Qwen3 text encoder is missing — download it to enable generation")
                }
                if vm.loadedTier == model.tier {
                    Button("Unload") { vm.unload() }
                        .buttonStyle(FxSecondaryButtonStyle(height: 30))
                        .help("Free the ~4–19 GB the model holds in memory — it stays on disk; the next render reloads it (~50 s extra).")
                }
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(FxIconButtonStyle(destructive: true))
                    .disabled(vm.downloadingTier != nil || vm.importing)
                    .help("Delete the transformer from disk")
                    .confirmationDialog(
                        "Delete \(model.title) from disk?",
                        isPresented: $confirmDelete, titleVisibility: .visible
                    ) {
                        Button("Delete (~\(model.estimatedSizeGB) GB)", role: .destructive) {
                            vm.delete(model.tier)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(model.isGated
                             ? "Deletion is immediate and permanent — getting it back means re-downloading ~\(model.estimatedSizeGB) GB with your HF token."
                             : "Deletion is immediate and permanent — getting it back means re-downloading ~\(model.estimatedSizeGB) GB.")
                    }
            }
        } else {
            Button { vm.download(model.tier) } label: {
                HStack(spacing: 6) { Image(systemName: "arrow.down.circle"); Text("Download") }
            }
            .buttonStyle(FxPrimaryButtonStyle(height: 30))
            .disabled(vm.downloadingTier != nil || vm.importing)
            .help(model.isGated
                  ? "Downloads the transformer + text encoder (~\(model.estimatedSizeGB) GB) — needs the token above and the accepted license"
                  : "Downloads the transformer + text encoder (~\(model.estimatedSizeGB) GB) — no account needed")
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.fxMono(11)).foregroundStyle(Color.fxText3)
            .padding(.vertical, 2).padding(.horizontal, 7)
            .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
    }
}

private struct AuxComponentRow: View {
    let comp: AuxComponent
    @Bindable var vm: ModelsViewModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 16))
                .foregroundStyle(Color.fxText2)
                .frame(width: 36, height: 36)
                .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text(comp.title).font(.fx(12.5, weight: .semibold)).foregroundStyle(Color.fxText)
                    Text(ByteFormat.string(comp.bytes)).font(.fxMono(11)).foregroundStyle(Color.fxText3)
                }
                Text(comp.note)
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { vm.deleteAux(comp) } label: { Image(systemName: "trash") }
                .buttonStyle(FxIconButtonStyle(destructive: true))
                .disabled(vm.downloadingTier != nil || vm.importing)
                .help("Delete from disk — it re-downloads automatically when needed")
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        .padding(.bottom, 10)
    }
}
