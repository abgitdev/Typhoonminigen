import SwiftUI

/// Inline icon helper for the Library: one point size + an equal square footprint + monochrome,
/// so SF Symbols with different intrinsic metrics (triangle vs star vs play vs gamecontroller)
/// read at the same visual weight instead of looking "bigger/smaller than the others".
private extension Image {
    func fxIcon(_ size: CGFloat = 11) -> some View {
        self.font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .frame(width: size + 4, height: size + 4)
    }
}

/// The Library — task-first browsing over the same chip engine. Slice 1: the SCENES tab
/// (studios → one-tap scene-recipes) + the honesty panel. One tap seeds the recipe's example
/// subject into the prompt, applies its chips, and jumps to Generate. Chips/Favorites/Examples tabs
/// land in later slices.
struct LibraryView: View {
    @Bindable var vm: GenerateViewModel
    let goToGenerate: () -> Void
    var openQueue: () -> Void = {}

    @AppStorage("librarySelectedStudio") private var studioID = "cinema"
    @State private var showHonesty = false
    @State private var queueNote = ""   // transient "Added X — N in queue" feedback

    private var recipes: [SceneRecipe] {
        PromptPresetLibrary.recipes.filter { $0.studio == studioID }
    }
    private var currentStudio: LibraryStudio? {
        PromptPresetLibrary.studios.first { $0.id == studioID }
    }

    // chip id → label, over built-ins + the generated Library chips.
    private static let chipLabel: [String: String] =
        Dictionary(PromptPresets.all.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                studioRow
                queueBar
                if let err = vm.errorMessage, !err.isEmpty {
                    Text(err)
                        .font(.fx(11.5)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !queueNote.isEmpty {
                    Text(queueNote)
                        .font(.fx(11.5)).foregroundStyle(Color.fxAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showHonesty {
                    honestyPanel
                } else {
                    sceneGrid
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Library").font(.fx(20, weight: .bold)).foregroundStyle(Color.fxText)
            Text("Pick what you want to make — one tap loads a ready scene into Generate. Edit the subject, then press Generate.")
                .font(.fx(12)).foregroundStyle(Color.fxText3)
        }
    }

    // ── Studio selector + honesty toggle ────────────────────────────────────────
    private var studioRow: some View {
        FxFlowLayout(spacing: 7, lineSpacing: 7) {
            ForEach(PromptPresetLibrary.studios) { studio in
                studioChip(studio)
            }
            honestyChip
        }
    }

    // ── Queue bar — appears once you've added scenes; run or open without leaving ────────
    @ViewBuilder private var queueBar: some View {
        if !vm.queue.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle").fxIcon().foregroundStyle(Color.fxAccent)
                Text(vm.queueRunning ? "Running — \(vm.queue.count) left" : "\(vm.queue.count) in queue")
                    .font(.fx(12, weight: .semibold)).foregroundStyle(Color.fxText)
                Spacer()
                if !vm.queueRunning {
                    Button { vm.runAll() } label: {
                        HStack(spacing: 6) { Image(systemName: "play.fill").fxIcon(10); Text("Run all") }
                    }
                    .buttonStyle(FxPrimaryButtonStyle(height: 28, fullWidth: false))
                    .help("Generate every queued task, one after another.")
                }
                Button { openQueue() } label: { Text("Open").font(.fx(11.5)) }
                    .buttonStyle(FxGhostButtonStyle(height: 28))
                    .help("Open the Queue tab to reorder, edit or remove tasks.")
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.fxAccent.opacity(0.4), lineWidth: 1))
        }
    }

    private func studioChip(_ studio: LibraryStudio) -> some View {
        let active = !showHonesty && studio.id == studioID
        return Button {
            showHonesty = false
            studioID = studio.id
            queueNote = ""
        } label: {
            HStack(spacing: 6) {
                Image(systemName: studio.icon).fxIcon()
                Text(studio.title).font(.fx(12, weight: active ? .semibold : .regular))
                if studio.badge == .yellow { FxDot(tone: .amber, size: 7) }
            }
            .foregroundStyle(active ? Color.fxText : Color.fxText2)
            .fxChip(accent: active, padV: 5, padH: 10)
        }
        .buttonStyle(.plain)
        .help(studio.priority == .top ? "Top-quality area for this model." : studio.title)
    }

    private var honestyChip: some View {
        Button { showHonesty.toggle(); queueNote = "" } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").fxIcon()
                Text("What this can't do").font(.fx(12, weight: showHonesty ? .semibold : .regular))
            }
            .foregroundStyle(showHonesty ? Color.fxDanger : Color.fxText3)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(showHonesty ? Color.fxDangerSoft : Color.fxHover,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("An honest list of what FLUX can't deliver (text, icons, real 3D, charts…) — and what to do instead.")
    }

    // ── Scene grid ──────────────────────────────────────────────────────────────
    private var sceneGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = currentStudio, s.badge == .yellow {
                Label("These are believable images, not exportable assets — see the note on each card.",
                      systemImage: "info.circle")
                    .font(.fx(11)).foregroundStyle(.orange)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                ForEach(recipes) { recipe in
                    sceneCard(recipe)
                }
            }
        }
    }

    /// Bundled preview thumbnail for a scene — one downscaled hero render per recipe id,
    /// shipped in Resources/ScenePreviews/<rcp.id>.jpg. nil → the card shows a placeholder.
    private static func previewURL(for id: String) -> URL? {
        guard let base = Bundle.module.resourceURL else { return nil }
        let u = base.appendingPathComponent("ScenePreviews/\(id).jpg")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Decode each bundled preview JPEG ONCE and keep it — `scenePreview` runs on every body
    /// re-eval (e.g. once per finished queue item), and re-reading + re-decoding tiny JPEGs from
    /// disk each time is needless main-thread work. Bounded by the recipe count (~110, ~512² each).
    private static var previewCache: [String: NSImage?] = [:]
    private static func previewImage(for id: String) -> NSImage? {
        if let cached = previewCache[id] { return cached }
        let img = previewURL(for: id).flatMap { NSImage(contentsOf: $0) }
        previewCache[id] = img
        return img
    }

    @ViewBuilder private func scenePreview(_ id: String) -> some View {
        if let img = Self.previewImage(for: id) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { Image(nsImage: img).resizable().scaledToFill() }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.fxText3.opacity(0.10))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "photo").fxIcon(22).foregroundStyle(Color.fxText3.opacity(0.5))
                }
        }
    }

    private func sceneCard(_ recipe: SceneRecipe) -> some View {
        Button {
            vm.loadScene(recipe)   // never blocks now — loads into the form (canvas untouched mid-render)
            goToGenerate()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                scenePreview(recipe.id)
                HStack(alignment: .top, spacing: 6) {
                    FxDot(tone: recipe.badge == .yellow ? .amber : .ok, size: 6)
                        .padding(.top, 3)   // pin the dot to the FIRST title line (the title box reserves 2 lines)
                    Text(recipe.title).font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText)
                        .lineLimit(2, reservesSpace: true)   // ALWAYS reserve 2 lines so every card is the same height
                    Spacer(minLength: 0)   // the ⊕/star overlay now sits over the image, so the title gets the full width
                }
                Text("“\(recipe.subjectExample)”")
                    .font(.fx(11.5)).foregroundStyle(Color.fxText2)
                    .italic().lineLimit(2, reservesSpace: true)
                Text(chipSummary(recipe.chipIDs))
                    .font(.fx(10)).foregroundStyle(Color.fxText3).lineLimit(1, reservesSpace: true)
                Text(recipe.note)
                    .font(.fx(10.5)).foregroundStyle(recipe.badge == .yellow ? .orange : Color.fxText3)
                    .lineLimit(3, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxCard(padding: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(recipe.note)\n\nTap to load this scene into Generate (edit the subject, then Generate or Add to queue).")
        // Add-to-queue is a SEPARATE button layered over the card (not nested inside it) so the tap
        // targets stay reliable on macOS — one click queues this scene without leaving the Library.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 7) {
                if recipe.featured {
                    Image(systemName: "star.fill").fxIcon(10).foregroundStyle(Color.fxAccent)
                }
                Button {
                    let n = vm.enqueueScene(recipe)
                    queueNote = "Added “\(recipe.title)” — \(n) in queue"
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.fxAccent)
                        .background(Circle().fill(.black.opacity(0.45)).padding(2))
                }
                .buttonStyle(.plain)
                .help("Add this scene to the queue without leaving — line up several, then Run all.")
            }
            .padding(10)
        }
    }

    private func chipSummary(_ ids: [String]) -> String {
        ids.compactMap { Self.chipLabel[$0] }.joined(separator: " · ")
    }

    // ── Honesty panel ───────────────────────────────────────────────────────────
    private var honestyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this app can't do — and what to use instead")
                .font(.fx(14, weight: .bold)).foregroundStyle(Color.fxText)
            Text("FLUX makes images, not assets. Here's where it falls short, honestly — so you don't waste a render.")
                .font(.fx(11.5)).foregroundStyle(Color.fxText3)
            ForEach(PromptPresetLibrary.redPanel) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.octagon.fill").fxIcon().foregroundStyle(Color.fxDanger)
                        Text(row.trap).font(.fx(12.5, weight: .semibold)).foregroundStyle(Color.fxText)
                    }
                    if !row.who.isEmpty {
                        Text(row.who).font(.fx(10.5)).foregroundStyle(Color.fxText3)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").fxIcon().foregroundStyle(Color.fxOk)
                        Text(row.reframe).font(.fx(11.5)).foregroundStyle(Color.fxText2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fxCard(padding: 12)
            }
        }
    }
}
