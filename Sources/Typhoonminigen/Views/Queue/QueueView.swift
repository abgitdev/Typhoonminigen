import SwiftUI

/// Task scheduler (#1): a list of queued generations, each its own prompt + settings. Build it
/// up on the Generate screen with "Add to queue", duplicate tasks (new / same / sequential seeds),
/// reorder, then "Run all". Shares GenerateViewModel's queue with the Generate screen.
struct QueueView: View {
    @Bindable var vm: GenerateViewModel
    var goToGenerate: () -> Void = {}

    // #2 inline-edit a pending task: which card is open + its working buffers.
    @State private var editingID: UUID?
    @State private var editPrompt = ""
    @State private var editW = ""
    @State private var editH = ""
    @State private var editSeed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.fxBorder).frame(height: 1)
            if vm.queue.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(vm.queue.enumerated()), id: \.element.id) { idx, item in
                            taskCard(item, index: idx)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.fxBg)
        // #2 don't let the inline editor linger on a task that started rendering or left the
        // queue — otherwise the open edit silently reverts to the running card and the edits vanish.
        .onChange(of: vm.currentItemID) { _, _ in clearEditIfGone() }
        .onChange(of: vm.queue.map(\.id)) { _, _ in clearEditIfGone() }
    }

    /// Drop an open inline edit if its task is no longer a pending, non-running queue item.
    private func clearEditIfGone() {
        if let e = editingID, !vm.queue.contains(where: { $0.id == e && $0.id != vm.currentItemID }) {
            editingID = nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Queue").font(.fx(16, weight: .bold)).foregroundStyle(Color.fxText)
                Text(headerSubtitle).font(.fx(11.5)).foregroundStyle(Color.fxText3)
            }
            Spacer()
            if vm.queueRunning {
                Button("Stop after this image") { vm.cancel() }
                    .buttonStyle(FxGhostButtonStyle(height: 30, accentText: true))
                    .help("The current image can't be interrupted — it finishes, then the queue stops; pending tasks are kept (Run all to resume).")
            } else if !vm.queue.isEmpty {
                Button { vm.clearQueue() } label: { Text("Clear") }
                    .buttonStyle(FxGhostButtonStyle(height: 30))
                    .help("Remove all pending tasks.")
                Button { vm.runAll() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill").font(.system(size: 12))
                        Text("Run all (\(vm.queue.count))")
                    }
                }
                .buttonStyle(FxPrimaryButtonStyle(height: 34, fullWidth: false))
                .help("Generate every task, one after another.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        if vm.queueRunning {
            return "Running · image \(min(vm.queueDone + 1, max(vm.queueTotal, 1))) of \(max(vm.queueTotal, 1))"
        }
        if vm.queue.isEmpty { return "No tasks yet" }
        return "\(vm.queue.count) task\(vm.queue.count == 1 ? "" : "s") ready"
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 40)).foregroundStyle(Color.fxText3.opacity(0.6))
            Text("Your task list is empty")
                .font(.fx(15, weight: .semibold)).foregroundStyle(Color.fxText2)
            Text("On the Generate screen, set up a prompt and press “Add to queue”. Line up several with different prompts, then run them all here.\n\nDuplicate a task to make the same prompt with new seeds.")
                .font(.fx(12.5)).foregroundStyle(Color.fxText3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            Button { goToGenerate() } label: {
                HStack(spacing: 7) { Image(systemName: "wand.and.stars"); Text("Go to Generate") }
            }
            .buttonStyle(FxPrimaryButtonStyle(height: 34, fullWidth: false))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Task card

    @ViewBuilder
    private func taskCard(_ item: GenerateViewModel.QueueItem, index: Int) -> some View {
        if editingID == item.id && item.id != vm.currentItemID {
            editCard(item, index: index)
        } else {
            displayCard(item, index: index)
        }
    }

    private func displayCard(_ item: GenerateViewModel.QueueItem, index: Int) -> some View {
        let isRunning = item.id == vm.currentItemID
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(isRunning ? Color.fxAccent : Color.fxInset).frame(width: 26, height: 26)
                if isRunning {
                    Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(Color.fxOnAccent)
                } else {
                    Text("\(index + 1)").font(.fxMono(11)).foregroundStyle(Color.fxText2)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.request.prompt.isEmpty ? "(empty prompt)" : item.request.prompt)
                    .font(.fx(12.5)).foregroundStyle(Color.fxText)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    chip(item.request.tier.shortName)
                    chip("\(item.request.width)×\(item.request.height)")
                    chip(seedText(item.request.seed))
                    if !item.request.loras.isEmpty { chip("LoRA ×\(item.request.loras.count)") }
                    if !item.referenceImages.isEmpty { chip("ref ×\(item.referenceImages.count)") }
                }
            }
            Spacer(minLength: 4)
            if isRunning {
                Text("rendering…").font(.fxMono(10.5)).foregroundStyle(Color.fxAccent)
            } else {
                actions(item, index: index)
            }
        }
        .padding(12)
        .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isRunning ? Color.fxAccent.opacity(0.6) : Color.fxBorder, lineWidth: 1))
    }

    private func actions(_ item: GenerateViewModel.QueueItem, index: Int) -> some View {
        HStack(spacing: 8) {
            Button { vm.moveTask(item.id, up: true) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0 || vm.queue[index - 1].id == vm.currentItemID)
                .help("Move up")
            Button { vm.moveTask(item.id, up: false) } label: { Image(systemName: "chevron.down") }
                .disabled(index == vm.queue.count - 1)
                .help("Move down")
            Button { beginEdit(item) } label: { Image(systemName: "pencil") }
                .help("Edit this task's prompt, size and seed")
            Menu {
                Button("Duplicate (new seed)") { vm.duplicateTask(item.id, count: 1, seedMode: .newRandom) }
                Button("Duplicate ×3 (new seeds)") { vm.duplicateTask(item.id, count: 3, seedMode: .newRandom) }
                Button("Duplicate ×5 (new seeds)") { vm.duplicateTask(item.id, count: 5, seedMode: .newRandom) }
                Button("Duplicate ×10 (new seeds)") { vm.duplicateTask(item.id, count: 10, seedMode: .newRandom) }
                Divider()
                Button("Duplicate (same seed)") { vm.duplicateTask(item.id, count: 1, seedMode: .same) }
                Button("Duplicate ×5 (sequential seeds)") { vm.duplicateTask(item.id, count: 5, seedMode: .sequential) }
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help("Duplicate this task — new random seeds give different variants of the same prompt.")
            Button { vm.removeQueued(item.id) } label: { Image(systemName: "xmark") }
                .help("Remove this task")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Color.fxText3)
    }

    // MARK: Inline edit (#2)

    private func beginEdit(_ item: GenerateViewModel.QueueItem) {
        editPrompt = item.request.prompt
        editW = String(item.request.width)
        editH = String(item.request.height)
        editSeed = item.request.seed.map(String.init) ?? ""
        editingID = item.id
    }

    private func saveEdit(_ item: GenerateViewModel.QueueItem) {
        let w = Int(editW.filter(\.isNumber)) ?? item.request.width
        let h = Int(editH.filter(\.isNumber)) ?? item.request.height
        // Distinguish "field cleared" (→ random seed) from "typed non-digits" (→ keep the current
        // seed; don't silently randomize a pinned seed because of a typo).
        let trimmedSeed = editSeed.trimmingCharacters(in: .whitespaces)
        let digits = trimmedSeed.filter(\.isNumber)
        let seed: UInt64?
        if trimmedSeed.isEmpty { seed = nil }
        else if digits.isEmpty { seed = item.request.seed }
        else { seed = UInt64(digits) ?? item.request.seed }
        vm.updateTask(item.id, prompt: editPrompt, width: w, height: h, seed: seed)
        editingID = nil
    }

    private func editCard(_ item: GenerateViewModel.QueueItem, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Editing task \(index + 1)")
                .font(.fx(11, weight: .semibold)).foregroundStyle(Color.fxText3)
            TextField("Prompt", text: $editPrompt, axis: .vertical)
                .textFieldStyle(.plain).font(.fx(12.5)).foregroundStyle(Color.fxText)
                .lineLimit(1...4)
                .padding(8)
                .background(Color.fxBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
            HStack(spacing: 8) {
                editField("Width", text: $editW, width: 72)
                editField("Height", text: $editH, width: 72)
                editField("Seed", text: $editSeed, width: 140, placeholder: "random")
                Spacer(minLength: 8)
                Button("Cancel") { editingID = nil }
                    .buttonStyle(FxGhostButtonStyle(height: 28))
                Button("Save") { saveEdit(item) }
                    .buttonStyle(FxPrimaryButtonStyle(height: 28, fullWidth: false))
            }
        }
        .padding(12)
        .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.fxAccent.opacity(0.6), lineWidth: 1))
    }

    private func editField(_ label: String, text: Binding<String>, width: CGFloat, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.fxMono(9)).foregroundStyle(Color.fxText3)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(.fxMono(11)).foregroundStyle(Color.fxText)
                .padding(.vertical, 5).padding(.horizontal, 8)
                .frame(width: width)
                .background(Color.fxBg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        }
    }

    private func chip(_ s: String) -> some View {
        Text(s).font(.fxMono(10)).foregroundStyle(Color.fxText3)
            .padding(.vertical, 2).padding(.horizontal, 7)
            .background(Color.fxBg, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.fxBorder, lineWidth: 1))
    }

    private func seedText(_ seed: UInt64?) -> String {
        guard let s = seed else { return "random" }
        let str = String(s)
        return str.count > 8 ? "seed \(str.prefix(6))…" : "seed \(str)"
    }
}
