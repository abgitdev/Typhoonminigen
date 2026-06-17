import SwiftUI

// ============================================================
//  First-launch tutorial — skippable multi-page tour (sheet).
//  The CALLER persists hasSeenTutorial; this view only calls
//  onClose. Update opt-in is written only by "Start creating".
// ============================================================

struct TutorialView: View {
    var onClose: () -> Void

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    @State private var pageIndex = 0
    // Mirrors the stored choice when one exists, so replaying the tour can't silently
    // re-enable a setting the user disabled. On first run it starts UNCHECKED — update checks
    // are genuinely opt-in, so "Start creating" must not enable them without an explicit tick.
    // "Start creating" is the only writer; "Skip tour" never touches it.
    @State private var autoUpdate = UserDefaults.standard.object(forKey: UpdateService.enabledKey) == nil ? false : UpdateService.isEnabled

    private struct Row: Identifiable {
        let term: String
        let detail: String
        var id: String { term }
    }

    private struct Page {
        let icon: String
        let title: String
        let intro: String
        let rows: [Row]
    }

    private static let pages: [Page] = [
        Page(
            icon: "sparkles",
            title: "Welcome to Typhoonminigen",
            intro: "Images are generated with FLUX.2 Klein entirely on this Mac — no cloud, no account, no subscription.",
            rows: [
                Row(term: "This tour", detail: "A few short pages with the essentials — about a minute."),
                Row(term: "Skippable", detail: "Skip now and re-open it any time from the Help tab."),
                Row(term: "Get started", detail: "Download a model in the Models tab, then describe an image in Generate."),
            ]),
        Page(
            icon: "square.stack.3d.up",
            title: "Pick your model",
            intro: "Two sizes of the same model — both download in the Models tab.",
            rows: [
                Row(term: "Klein 4B", detail: "Light — about 8 GB on disk, runs fine on 16 GB Macs."),
                Row(term: "Klein 9B", detail: "Best quality — about 26 GB on disk; the license is gated, so it needs a free Hugging Face token."),
                Row(term: "Download", detail: "Start it in the Models tab and watch the progress there."),
                Row(term: "First render", detail: "Also loads the model into memory — expect roughly an extra minute."),
            ]),
        Page(
            icon: "wand.and.stars",
            title: "Generate",
            intro: "Describe the image in plain language — any language works.",
            rows: [
                Row(term: "Prompt", detail: "40–70 words is the sweet spot: subject, scene, light, mood."),
                Row(term: "Presets & LOOKS", detail: "Chips append proven phrases to your prompt; LOOKS bundle several at once."),
                Row(term: "Aspect chips", detail: "1:1, 4:5, 3:2, 16:9 and 9:16 all stay near Klein's ~1 MP sweet spot — upscale ×2/×4 afterwards."),
                Row(term: "Seed", detail: "The same seed with the same settings reproduces an image exactly."),
                Row(term: "Batch", detail: "Renders several variants — a fixed seed runs seed, seed+1, …; an empty seed gives each image a fresh random one."),
                Row(term: "Tidy up", detail: "The chevron by the prompt hides the panels below it for a cleaner view."),
                Row(term: "Hide the side panels", detail: "The two icons in the title bar fold away the left navigation and the right telemetry panel — more room on a small screen or for a focused view."),
            ]),
        Page(
            icon: "books.vertical",
            title: "Library — ready-made scenes",
            intro: "Don't feel like writing a prompt? Pick a ready scene and make it yours.",
            rows: [
                Row(term: "Studios", detail: "Browse scenes by category — portrait, product, cinema, interiors, food, cars and more."),
                Row(term: "Preview & load", detail: "Each card shows an example image of the result; tap it to load that scene into Generate, then just swap the subject."),
                Row(term: "Add to queue", detail: "The ⊕ on a card lines the scene up in the queue — stack several, then Run all."),
                Row(term: "Honest notes", detail: "Each card says what Klein can't nail, and a panel lists what to avoid — legible text, logos, real 3D files."),
            ]),
        Page(
            icon: "list.bullet.rectangle",
            title: "Queue a batch of tasks",
            intro: "Line up many different prompts and let them render one after another.",
            rows: [
                Row(term: "Add to queue", detail: "On Generate, set up a prompt and press “Add to queue” — repeat with different prompts to build a list."),
                Row(term: "Run all", detail: "Open the Queue tab and press Run all; images render in order and land in the Gallery."),
                Row(term: "Duplicate", detail: "Copy a task with new random seeds (different variants), the same seed, or sequential seeds."),
                Row(term: "Reorder & stop", detail: "Move tasks up or down, or remove them; Stop finishes the current image and keeps the rest queued."),
            ]),
        Page(
            icon: "photo.on.rectangle.angled",
            title: "References & LoRA",
            intro: "Guide the result with images, not just words.",
            rows: [
                Row(term: "References", detail: "Drop up to 3 images — Klein keeps faces and composition while your prompt drives the scene."),
                Row(term: "No masks", detail: "Klein regenerates the whole image; there is no inpaint brush."),
                Row(term: "Describe with AI", detail: "Turns a reference into editable prompt text."),
                Row(term: "LoRA", detail: "Adapters add styles or characters — Klein-architecture only; trigger words append automatically."),
            ]),
        Page(
            icon: "photo.stack",
            title: "Your images remember everything",
            intro: "Every image you make carries its own recipe.",
            rows: [
                Row(term: "PNG recipe", detail: "Prompt, seed, size, model and LoRA are embedded in every PNG."),
                Row(term: "Remix", detail: "Any gallery image loads its full recipe back into the form."),
                Row(term: "Restore a recipe", detail: "Drop a Typhoonminigen PNG on the canvas, or use the ⬇ button by the prompt — even for an image you deleted."),
                Row(term: "Zoom & select", detail: "Scroll to zoom the result (double-click resets); in the Gallery, “Select” deletes or exports many images at once."),
                Row(term: "Drag out", detail: "Drag images straight to Finder, chats, or editors."),
                Row(term: "Careful", detail: "Re-saving as JPEG strips the recipe, and deleting here is permanent — no Trash."),
            ]),
        Page(
            icon: "lock.shield",
            title: "Private by design",
            intro: "Everything runs locally — prompts and images never leave this Mac.",
            rows: [
                Row(term: "No accounts", detail: "No sign-in, no telemetry, no cloud rendering."),
                Row(term: "Network", detail: "Used only to download models and the upscaler."),
                Row(term: "Your call", detail: "The one optional network feature is below — it stays off unless you leave it checked."),
            ]),
    ]

    private var isLastPage: Bool { pageIndex == Self.pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            pageView(Self.pages[pageIndex])
                .id(pageIndex)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            bottomBar
        }
        .padding(24)
        .frame(width: 680)
        .frame(minHeight: 540)
        .background(Color.fxBg)
        .animation(.easeInOut(duration: 0.22), value: pageIndex)
    }

    // ── Page content ─────────────────────────────────────────────────────────

    private func pageView(_ page: Page) -> some View {
        VStack(spacing: 14) {
            Image(systemName: page.icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.fxAccent)
                .frame(height: 60)
                .padding(.top, 26)
            Text(page.title)
                .font(.fx(20, weight: .bold))
                .foregroundStyle(Color.fxText)
            Text(page.intro)
                .font(.fx(13))
                .foregroundStyle(Color.fxText2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(page.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.term)
                            .font(.fx(12.5, weight: .semibold))
                            .foregroundStyle(Color.fxAccent)
                            .frame(width: 130, alignment: .trailing)
                        Text(row.detail)
                            .font(.fx(12.5))
                            .foregroundStyle(Color.fxText2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: 540)
            .padding(.top, 12)
            if isLastPage {
                updateCheckbox
                    .frame(maxWidth: 540)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var updateCheckbox: some View {
        Button { autoUpdate.toggle() } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(autoUpdate ? Color.fxAccent : Color.fxInset)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(autoUpdate ? Color.fxAccent : Color.fxBorderStrong, lineWidth: 1))
                    .overlay {
                        if autoUpdate {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.fxOnAccent)
                        }
                    }
                    .frame(width: 16, height: 16)
                (Text("Check for updates automatically ").foregroundColor(.fxText2)
                 + Text("— asks api.github.com on launch (at most once an hour), nothing else is sent").foregroundColor(.fxText3))
                    .font(.fx(12.5))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("At most once an hour the app asks api.github.com for the newest release and shows a banner if there is one. No prompts, images, or identifiers are sent. Applied only when you press Start creating — Skip tour leaves update checks unchanged.")
    }

    // ── Bottom bar ───────────────────────────────────────────────────────────

    private var bottomBar: some View {
        ZStack {
            HStack(spacing: 10) {
                Button("Skip tour") { onClose() }
                    .buttonStyle(FxGhostButtonStyle(height: 30))
                    .keyboardShortcut(.cancelAction)
                    .help("Close the tour without changing any settings — automatic update checks are left unchanged (Esc). Re-open the tour any time from the Help tab.")
                Spacer()
                Button("Back") { pageIndex = max(0, pageIndex - 1) }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .opacity(pageIndex == 0 ? 0 : 1)
                    .disabled(pageIndex == 0)
                    .help("Previous page")
                if isLastPage {
                    Button("Start creating") {
                        UpdateService.setEnabled(autoUpdate)
                        onClose()
                    }
                    .buttonStyle(FxPrimaryButtonStyle(height: 30))
                    .keyboardShortcut(.defaultAction)
                    .help("Finish the tour — applies the update-check choice above, then closes (Return)")
                } else {
                    Button("Next") { pageIndex = min(Self.pages.count - 1, pageIndex + 1) }
                        .buttonStyle(FxPrimaryButtonStyle(height: 30))
                        .keyboardShortcut(.defaultAction)
                        .help("Next page (Return)")
                }
            }
            pageDots
        }
        .padding(.top, 16)
    }

    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.pages.count, id: \.self) { i in
                Button { pageIndex = i } label: {
                    Circle()
                        .fill(i == pageIndex ? Color.fxAccent : Color.fxText3)
                        .frame(width: 6, height: 6)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to page \(i + 1) of \(Self.pages.count)")
            }
        }
    }
}
