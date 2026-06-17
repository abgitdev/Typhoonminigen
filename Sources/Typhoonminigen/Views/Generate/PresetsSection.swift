import SwiftUI

/// Collapsible "Presets" card — clickable chips whose verified phrases auto-append to the prompt
/// at generation time. A LOOKS row of one-tap bundles sits on top; categories are grouped under
/// four section headers (Scene / Composition / Look / Subject — lighting first, it's the
/// highest-impact axis) and EACH category is an independently collapsible disclosure row
/// (the active selection shows as an amber summary on the row so it reads at a glance).
/// Single-fact categories are single-select; lighting, style, color and layout stack.
struct PresetsSection: View {
    @Bindable var vm: GenerateViewModel
    @State private var expanded = false
    @State private var openCategories: Set<String> = [PromptPresetCategory.lighting.id]
    @State private var newChipText: [String: String] = [:]   // per-category draft for "add your own"

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 16 : 0) {
            header
            if expanded {
                looksSection
                ForEach(PromptPresetGroup.allCases) { group in
                    groupSection(group)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 12)
    }

    // ── LOOKS — one-tap chip bundles (clear-then-set; re-tap clears) ──────────
    private var looksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOOKS")
                .font(.fx(10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.fxAccent)
            FxFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(PromptPresets.bundles) { bundle in
                    bundleChip(bundle)
                }
            }
            Text("A look replaces the current chip selection — tap again to clear.")
                .font(.fx(10.5)).foregroundStyle(Color.fxText3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bundleChip(_ bundle: PresetBundle) -> some View {
        let active = vm.bundleIsActive(bundle)
        return Button { vm.applyBundle(bundle) } label: {
            HStack(spacing: 5) {
                if active { FxDot(tone: .amber, size: 6) }
                Text(bundle.label).font(.fx(11.5, weight: .medium))
                    .foregroundStyle(active ? Color.fxText : Color.fxText2)
            }
            .fxChip(accent: active, padV: 4, padH: 9)
        }
        .buttonStyle(.plain)
        .help(bundleHelp(bundle))
    }

    private func bundleHelp(_ bundle: PresetBundle) -> String {
        let labels = bundle.chipIDs.compactMap { id in
            PromptPresets.all.first { $0.id == id }?.label
        }
        return "Replaces the current selection. Sets: " + labels.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.aperture").font(.system(size: 13)).foregroundStyle(Color.fxText3)
            Text("Presets").font(.fx(12, weight: .semibold)).foregroundStyle(Color.fxText2)
            if vm.hasPresets {
                Text("\(vm.selectedPresetIDs.count)")
                    .font(.fxMono(10)).foregroundStyle(Color.fxAccent)
                    .fxChip(accent: true, padV: 1, padH: 6)
            }
            Spacer()
            if vm.hasPresets {
                Button("Clear") { vm.clearPresets() }
                    .buttonStyle(FxGhostButtonStyle(height: 22, accentText: true))
                    .help("Deselect every chip — your custom chips are kept, only the selection is cleared.")
            }
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10)).foregroundStyle(Color.fxText3)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }
        .help("Show or hide the preset chips. Selected chips keep applying even while collapsed — the amber count shows how many are active.")
    }

    private func groupSection(_ group: PromptPresetGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title.uppercased())
                .font(.fx(10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.fxAccent)
            ForEach(group.categories) { category in
                categorySection(category)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func categorySection(_ category: PromptPresetCategory) -> some View {
        let isOpen = openCategories.contains(category.id)
        let chosen = PresetCatalog.presets(for: category)
            .filter { vm.selectedPresetIDs.contains($0.id) }
            .map(\.label)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { openCategories.remove(category.id) } else { openCategories.insert(category.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.fxText3)
                        .frame(width: 10)
                    Text(category.title).fxLabel()
                    Spacer(minLength: 8)
                    if !chosen.isEmpty {
                        Text(chosen.joined(separator: ", "))
                            .font(.fx(10.5))
                            .foregroundStyle(Color.fxAccent)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Expand or collapse this category. The amber text on the row shows which chips are currently selected in it.")

            if isOpen {
                if (category == .style || category == .color), !vm.activeLoRASlots.isEmpty {
                    Text("A LoRA is active — style chips may fight it.")
                        .font(.fx(10.5)).foregroundStyle(.orange)
                }
                FxFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(PresetCatalog.presets(for: category)) { preset in
                        chip(preset)
                    }
                }
                addChipRow(category)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline "add your own phrase" — the chip persists and behaves like a built-in.
    /// Also hosts the "show hidden" restore when built-ins were hidden via right-click.
    private func addChipRow(_ category: PromptPresetCategory) -> some View {
        HStack(spacing: 7) {
            TextField("Your phrase: term + visible effect, 4–10 words", text: draftBinding(category))
                .textFieldStyle(.plain)
                .font(.fx(11.5)).foregroundStyle(Color.fxText)
                .padding(.vertical, 5).padding(.horizontal, 9)
                .fxInsetField(radius: 7)
                .onSubmit { addChip(category) }
                .help("Type a short phrase and press Return — it becomes a permanent custom chip in this category, appended to the prompt like a built-in. Right-click the chip to delete it.")
            Button("Add") { addChip(category) }
                .buttonStyle(FxGhostButtonStyle(height: 24, accentText: true))
                .disabled((newChipText[category.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Save the phrase as a custom chip — it persists across launches and toggles like a built-in.")
            let hidden = CustomPresetStore.shared.hiddenCount(in: category)
            if hidden > 0 {
                Button("show \(hidden) hidden") { CustomPresetStore.shared.unhideAll(in: category) }
                    .buttonStyle(.plain)
                    .font(.fx(10)).foregroundStyle(Color.fxText3)
                    .help("Restore the built-in chips you hid in this category via right-click.")
            }
        }
    }

    private func draftBinding(_ category: PromptPresetCategory) -> Binding<String> {
        Binding(get: { newChipText[category.id] ?? "" },
                set: { newChipText[category.id] = $0 })
    }

    private func addChip(_ category: PromptPresetCategory) {
        CustomPresetStore.shared.add(phrase: newChipText[category.id] ?? "", to: category)
        newChipText[category.id] = ""
    }

    private func chip(_ preset: PromptPreset) -> some View {
        let active = vm.selectedPresetIDs.contains(preset.id)
        return Button { vm.togglePreset(preset.id) } label: {
            HStack(spacing: 5) {
                if active { FxDot(tone: .amber, size: 6) }
                Text(preset.label).font(.fx(11.5)).foregroundStyle(active ? Color.fxText : Color.fxText2)
            }
            .fxChip(accent: active, padV: 4, padH: 9)
        }
        .buttonStyle(.plain)
        .help("Adds to the prompt: \(preset.phrase) (right-click to \(preset.id.hasPrefix("custom.") ? "delete" : "hide"))")
        .contextMenu {
            if preset.id.hasPrefix("custom.") {
                Button("Delete \u{201C}\(preset.label)\u{201D}", role: .destructive) {
                    vm.deselectPreset(preset.id)   // persists — a plain remove was lost on quit
                    CustomPresetStore.shared.remove(preset.id)
                }
            } else {
                // Built-ins live in code, so "delete" = hide (restorable per category).
                Button("Hide \u{201C}\(preset.label)\u{201D}", role: .destructive) {
                    vm.deselectPreset(preset.id)   // persists — a plain remove was lost on quit
                    CustomPresetStore.shared.hide(preset.id)
                }
            }
        }
    }
}
