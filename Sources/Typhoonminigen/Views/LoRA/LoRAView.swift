import SwiftUI
import UniformTypeIdentifiers

struct LoRAView: View {
    @Bindable var vm: LoRAViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SectionTitle(text: "LoRA")
                    Spacer()
                    Button { vm.importLoRA() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 12))
                            Text("Import .safetensors")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                    .help("Copy a LoRA adapter into the app — it must be trained for Klein 9B (dim 4096) or Klein 4B (dim 3072)")
                }

                Text("Only standard LoRA files load — the diffusers lora_A/lora_B layout (e.g. ai-toolkit LoRA mode). LoKr / LoHa / LyCORIS, kohya-format, and FLUX.1 / Dev adapters won't work. It must also match its Klein tier — 9B = dim 4096, 4B = dim 3072 (not interchangeable). Any trigger word is added to the prompt automatically at generation time.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.top, 8).padding(.bottom, 18)

                HStack {
                    Text("INSTALLED").font(.fx(11, weight: .semibold)).tracking(0.5).foregroundStyle(Color.fxText3)
                    Spacer()
                    Text("\(vm.items.count) \(vm.items.count == 1 ? "adapter" : "adapters")")
                        .font(.fxMono(11)).foregroundStyle(Color.fxText3)
                }
                .padding(.bottom, 12)

                if vm.items.isEmpty {
                    Text("No adapters. Import a .safetensors for Klein 9B or Klein 4B.")
                        .font(.fx(12)).foregroundStyle(Color.fxText3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 14)
                } else {
                    ForEach(vm.items) { item in
                        LoRARow(item: item, vm: vm)
                    }
                }

                DropZoneImport(vm: vm)
                    .padding(.top, 4)

                if let msg = vm.lastAction {
                    Text(msg.text).font(.fx(11))
                        .foregroundStyle(msg.isError ? Color.fxDanger : Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.fxBg)
        .task { vm.reload() }
    }
}

private struct LoRARow: View {
    let item: LoRAItem
    @Bindable var vm: LoRAViewModel
    @State private var triggerText: String = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                tile
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.fileName).font(.fxMono(12.5)).foregroundStyle(Color.fxText).lineLimit(1)
                    HStack(spacing: 8) {
                        if item.isCompatible {
                            HStack(spacing: 6) { FxDot(tone: .ok, size: 7); Text("for \(item.tier?.shortName ?? "Klein")") }.fxPillOk()
                                .help("Built for \(item.tier?.shortName ?? "Klein"). It's selectable on the Generate tab only while that model is the active tier.")
                        } else {
                            HStack(spacing: 6) {
                                FxDot(tone: .amber, size: 7); Text("incompatible")
                            }
                            .font(.fxMono(11)).foregroundStyle(Color.fxAccent)
                            .padding(.vertical, 4).padding(.horizontal, 9)
                            .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .help(item.note)
                        }
                        tag(item.note)
                        tag(fileSize)
                    }
                }
                Spacer(minLength: 8)
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(FxIconButtonStyle(destructive: true))
                    .help("Delete the adapter file from disk — permanent, no Trash (asks for confirmation). If it's selected on the Generate tab it will be deactivated")
                    .confirmationDialog(
                        "Delete \u{201C}\(item.fileName)\u{201D}?",
                        isPresented: $confirmDelete, titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) { vm.delete(item) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The .safetensors file is removed from disk immediately — there is no Trash to recover it from.")
                    }
            }

            if item.isCompatible {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Trigger word").fxLabel()
                    HStack(spacing: 10) {
                        TextField("this LoRA's own trigger phrase (optional)", text: $triggerText)
                            .textFieldStyle(.plain)
                            .font(.fxMono(13)).foregroundStyle(Color.fxText)
                            .onSubmit { vm.setTrigger(triggerText, for: item) }
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .fxInsetField(radius: 9)
                            .help("This LoRA's trigger phrase (from its HuggingFace page) — auto-added to the prompt whenever the LoRA is active. Press Return or Save to store it; leave empty if the LoRA needs none")
                        Button("Save") { vm.setTrigger(triggerText, for: item) }
                            .buttonStyle(FxPrimaryButtonStyle(height: 30))
                            .disabled(triggerText == item.trigger)
                            .opacity(triggerText == item.trigger ? 0.5 : 1)
                            .help("Saved per adapter — auto-added to the prompt whenever this LoRA is active")
                    }
                    Text("The LoRA's trigger word (from its HuggingFace page). It's added to the prompt automatically.")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                }
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 10, x: 0, y: 6)
        .padding(.bottom, 12)
        .onAppear { triggerText = item.trigger }
        // A same-named adapter re-imported reuses this row's identity, so onAppear won't re-fire —
        // sync the field when the underlying trigger changes so it can't show the stale value.
        .onChange(of: item.trigger) { _, newValue in triggerText = newValue }
    }

    private var tile: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.system(size: 19))
            .foregroundStyle(Color.fxAccent)
            .frame(width: 42, height: 42)
            .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.fxAccentLine, lineWidth: 1))
    }

    private var fileSize: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path),
              let size = attrs[.size] as? Int64 else { return "—" }
        return ByteFormat.string(size)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.fxMono(11)).foregroundStyle(Color.fxText3).lineLimit(1)
            .padding(.vertical, 2).padding(.horizontal, 7)
            .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
    }
}

private struct DropZoneImport: View {
    @Bindable var vm: LoRAViewModel
    @State private var isTargeted = false

    var body: some View {
        FxDropZone(isTargeted: isTargeted) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 16)).foregroundStyle(Color.fxText3.opacity(0.8))
                (Text("Drop a ").foregroundColor(.fxText3)
                 + Text(".safetensors").foregroundColor(.fxAccent)
                 + Text(" here to add another adapter").foregroundColor(.fxText3))
                    .font(.fx(12))
            }
        }
        .onTapGesture { vm.importLoRA() }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else {
                    DispatchQueue.main.async { vm.lastAction = .error("Couldn't read the dropped item — drag a .safetensors FILE from Finder.") }
                    return
                }
                DispatchQueue.main.async { vm.importLoRA(from: url) }
            }
            return true
        }
        .help("Drop a .safetensors here — or click to choose one. Klein-architecture only: 9B = dim 4096, 4B = dim 3072; FLUX.1/Dev adapters won't load")
    }
}
