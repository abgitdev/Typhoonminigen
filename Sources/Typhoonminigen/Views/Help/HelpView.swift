import SwiftUI

struct HelpView: View {
    var onShowTutorial: () -> Void = {}
    var onShowWhatsNew: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SectionTitle(text: "Help")
                    Spacer()
                    Text("quick reference").font(.fxMono(11)).foregroundStyle(Color.fxText3)
                }

                Text("Typhoonminigen renders images with FLUX.2 Klein entirely on this Mac — and every control explains itself: hover anything for a tooltip.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.top, 8).padding(.bottom, 14)

                HStack(spacing: 10) {
                    Button {
                        onShowTutorial()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkles.rectangle.stack").font(.system(size: 12))
                            Text("Show the welcome tour again")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                    .help("Re-watch the welcome tour. Finishing it applies the update-check choice on its last page; skipping changes nothing.")

                    Button {
                        onShowWhatsNew()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "wand.and.sparkles").font(.system(size: 12))
                            Text("What's new in \(AppVersion.current)")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                    .help("The changes in this version — the same window that appears once after every update.")
                }

                HelpSection(title: "GETTING STARTED") {
                    HelpRow("Klein 4B vs 9B",
                            "4B is the smaller tier — less disk and RAM; 9B renders finer detail but costs more of both. Install either (or both) in Models.")
                    HelpRow("Downloading",
                            "The Models tab handles every download; the text encoder and other components fetch alongside the transformer automatically.")
                    HelpRow("HF token",
                            "Only the gated Klein 9B needs a Hugging Face token — it's stored in the macOS Keychain and sent only to huggingface.co to authenticate the gated download (never to anyone else). 4B downloads without an account.")
                    HelpRow("First render",
                            "Loads the model into RAM first — expect about a minute before the first image; later renders skip it.")
                    HelpRow("Removing everything",
                            "Models and the HuggingFace cache are several GB and live in your Library — dragging the app to the Trash does NOT remove them. To reclaim the space, use System → \u{201C}Remove all data\u{201D} (wipes models, gallery, caches and logs) BEFORE you delete the app.")
                }

                HelpSection(title: "GENERATE") {
                    HelpRow("Prompt",
                            "Plain natural language, any language — Klein renders best at 40–70 words.")
                    HelpRow("Presets & LOOKS",
                            "Chips that append curated style phrases to your prompt; toggle one off to remove its phrase.")
                    HelpRow("Aspect chips",
                            "Every ratio — including portrait 9:16 — targets ~1 megapixel, Klein's sweet spot. Render small, upscale after.")
                    HelpRow("Seed",
                            "The same seed with the same settings reproduces an image exactly. Empty = a new random seed every render.")
                    HelpRow("Batch",
                            "The same prompt rendered N times — with a fixed seed the series runs seed, seed+1, …; with an empty Seed field every image gets a fresh random seed.")
                    HelpRow("Hide panels",
                            "The chevron next to the prompt collapses the size / presets / references panels for a cleaner view; the ⬇ button imports a recipe from any PNG. The two icons in the title bar fold away the left navigation and the right telemetry panel.")
                    HelpRow("Enhance prompt",
                            "Qwen3 rewrites the prompt with extra descriptive detail before rendering. Text-only — it is ignored when references are attached.")
                    HelpRow("Live preview",
                            "Decodes a preview during the render; turn on “Show every step” to watch all four steps (the first ones look noisy).")
                }

                HelpSection(title: "LIBRARY") {
                    HelpRow("Studios & scenes",
                            "Ready-made scene recipes grouped by studio (portrait, product, cinema, interiors, food, cars…). Each card shows an example preview of what it produces.")
                    HelpRow("Load a scene",
                            "Tap a card to load its subject and style into Generate — edit the subject, then render or add to the queue.")
                    HelpRow("Add to queue",
                            "The ⊕ on a card queues that scene directly; stack several and Run all from the Queue tab.")
                    HelpRow("Honest limits",
                            "Each card carries a note on what the model can't nail, and a panel lists traps to avoid — legible text, logos and brands, real 3D or vector assets.")
                }

                HelpSection(title: "QUEUE") {
                    HelpRow("Add to queue",
                            "Builds a task from the current form without running it — line up many different prompts, then run them together.")
                    HelpRow("Run all",
                            "The Queue tab runs every task in order; finished images land in the Gallery.")
                    HelpRow("Duplicate",
                            "Copy a task with new random seeds (variants), the same seed, or sequential seeds — the fast way to make one prompt × N seeds.")
                    HelpRow("Reorder & stop",
                            "Move tasks up/down or remove them. Stop finishes the current image and keeps the rest queued — Run all resumes.")
                }

                HelpSection(title: "REFERENCES (I2I)") {
                    HelpRow("Slots",
                            "Up to 3 reference images; the first one snaps the output size to match.")
                    HelpRow("No masks",
                            "The engine regenerates the whole scene guided by the references — there is no inpainting or partial edit.")
                    HelpRow("Describe with AI",
                            "A local vision model appends an editable description of the reference to the prompt.")
                }

                HelpSection(title: "LORA") {
                    HelpRow("Compatibility",
                            "Klein-architecture adapters only — 9B = dim 4096, 4B = dim 3072. FLUX.1 / Dev adapters won't load.")
                    HelpRow("Trigger words",
                            "Saved per adapter and appended to the prompt automatically while the LoRA is active.")
                    HelpRow("Switching",
                            "Changing the adapter set or a strength reloads clean model weights first — instant when cached, up to ~1 min from a cold disk.")
                }

                HelpSection(title: "GALLERY & RECIPES") {
                    HelpRow("PNG recipe",
                            "Every generated PNG embeds its recipe — prompt, seed, size, model, LoRA. References aren't embedded; Remix reloads them from their original files while those still exist on disk.")
                    HelpRow("Remix",
                            "Loads an image's recipe back into the Generate form.")
                    HelpRow("Drop / Import",
                            "Drop any Typhoonminigen PNG onto the canvas, or use the ⬇ button by the prompt, to restore its recipe — even for an image you deleted.")
                    HelpRow("Select",
                            "“Select” in the Gallery toolbar turns on multi-select — Shift-click a range, then delete or export them all at once.")
                    HelpRow("Zoom",
                            "Scroll the wheel over a result to zoom in; double-click to reset.")
                    HelpRow("Drag out",
                            "Drag images from the canvas, gallery, or detail view — into Finder, a chat, an editor…")
                    HelpRow("JPEG",
                            "Re-saving a PNG as JPEG strips the recipe — keep the PNG if you want Remix later.")
                    HelpRow("Delete",
                            "Removal is immediate and permanent — there is no Trash.")
                }

                HelpSection(title: "UPSCALE") {
                    HelpRow("Real-ESRGAN",
                            "×2 or ×4 upscaling saves a new PNG next to the original — the original is untouched.")
                }

                HelpSection(title: "SYSTEM & PRIVACY") {
                    HelpRow("Local only",
                            "Generation runs on this Mac — images and prompts never leave it.")
                    HelpRow("Network",
                            "Used only to download models (Hugging Face), the upscaler (GitHub) and — if enabled — an update check (api.github.com), at most once an hour.")
                    HelpRow("Unload",
                            "Frees the RAM the model holds; it stays on disk and reloads on the next render.")
                    HelpRow("Clear caches",
                            "Removes rebuildable thumbnails — full-size images stay.")
                    HelpRow("Logs",
                            "Kept in a local file (plus one rotated backup) you can clear from System.")
                }

                HelpSection(title: "SHORTCUTS") {
                    HelpKeyRow("⌘⏎", "Generate — or add to the queue while a run is busy.")
                    HelpKeyRow("Esc", "Stop — the current frame finishes and is kept; pending tasks stay queued (Run all resumes).")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.fxBg)
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.fx(11, weight: .semibold)).tracking(0.5).foregroundStyle(Color.fxText3)
                .padding(.bottom, 2)
            content
        }
        .padding(.top, 22)
    }
}

private struct HelpRow: View {
    let term: String
    let detail: String

    init(_ term: String, _ detail: String) {
        self.term = term
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(term)
                .font(.fx(12, weight: .semibold)).foregroundStyle(Color.fxText)
                .frame(width: 130, alignment: .leading)
            Text(detail)
                .font(.fx(12)).foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

private struct HelpKeyRow: View {
    let keys: String
    let detail: String

    init(_ keys: String, _ detail: String) {
        self.keys = keys
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(keys)
                .font(.fxMono(12)).foregroundStyle(Color.fxText)
                .frame(width: 130, alignment: .leading)
            Text(detail)
                .font(.fx(12)).foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                .frame(maxWidth: 620, alignment: .leading)
        }
    }
}
