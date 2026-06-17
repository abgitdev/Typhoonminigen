import SwiftUI

// ============================================================
//  "What's new" — one-time sheet after an update (the CALLER
//  decides when to show it and persists lastSeenWhatsNewVersion;
//  this view only renders releases and calls onClose).
// ============================================================

struct WhatsNewView: View {
    /// Releases strictly newer than this version are shown; when none qualify
    /// (re-opened from Help right after dismissing), the latest release shows.
    var since: String = "0"
    var onClose: () -> Void = {}

    private struct Highlight: Identifiable {
        let icon: String
        let term: String
        let detail: String
        var id: String { term }
    }

    private struct Release {
        let version: String
        let highlights: [Highlight]
    }

    // Newest first. 1.0 is the public start — pre-release patch notes are intentionally
    // dropped. Going forward, add ONE entry per release describing only what's new to the user.
    private static let releases: [Release] = [
        Release(version: "1.0", highlights: [
            Highlight(icon: "bolt.fill", term: "Local image generation",
                      detail: "Typhoonminigen runs the FLUX.2 Klein model entirely on your Mac \u{2014} no cloud, no account, nothing leaves the machine. Write a prompt in any language and create images fully offline."),
            Highlight(icon: "cpu", term: "Two model sizes",
                      detail: "Klein 4B is light and fast; Klein 9B is the quality tier. The app suggests the right one for your Mac's memory, and you can switch any time."),
            Highlight(icon: "books.vertical", term: "A Library of ready-made scenes",
                      detail: "Pick a studio \u{2014} Cinema, Portrait, Product, Interiors, Food, Auto, Nature, Anime and more \u{2014} tap a scene, drop in your own subject and generate. Each card is honest about what the model can and can't do."),
            Highlight(icon: "photo.on.rectangle.angled", term: "References, LoRA & a recipe in every image",
                      detail: "Guide a render with up to three reference images, load your own LoRA adapters, and queue a whole batch. Every saved PNG carries its full recipe \u{2014} drop one back in to remix it."),
            Highlight(icon: "lock.shield", term: "Private by design",
                      detail: "Your prompts, images and settings stay on your Mac and are erasable at any time. The only time the app goes online is to download the model weights once."),
        ]),
    ]

    private var shownReleases: [Release] {
        // Drift guard: a version bump without a matching release entry would show stale notes
        // under the new version header. Fires in Debug builds only.
        assert(Self.releases.first?.version == AppVersion.current,
               "WhatsNewView.releases is missing an entry for \(AppVersion.current)")
        let newer = Self.releases.filter { UpdateService.isNewer(remote: $0.version, local: since) }
        if newer.isEmpty, let latest = Self.releases.first { return [latest] }
        return newer
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Color.fxAccent)
                .frame(height: 54)
                .padding(.top, 20)
            Text("What's new")
                .font(.fx(20, weight: .bold))
                .foregroundStyle(Color.fxText)
                .padding(.top, 10)
            Text("Typhoonminigen \(AppVersion.current)")
                .font(.fxMono(11.5))
                .foregroundStyle(Color.fxText3)
                .padding(.top, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(shownReleases, id: \.version) { release in
                        VStack(alignment: .leading, spacing: 11) {
                            Text("VERSION \(release.version)")
                                .font(.fx(11, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(Color.fxText3)
                            ForEach(release.highlights) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.fxAccent)
                                        .frame(width: 22)
                                    Text(item.term)
                                        .font(.fx(12.5, weight: .semibold))
                                        .foregroundStyle(Color.fxText)
                                        .frame(width: 150, alignment: .leading)
                                    Text(item.detail)
                                        .font(.fx(12.5))
                                        .foregroundStyle(Color.fxText2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            Button("Got it") { onClose() }
                .buttonStyle(FxPrimaryButtonStyle(height: 30))
                .keyboardShortcut(.defaultAction)
                .help("Close — this window won't show again until the next update (Return)")
                .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 680)
        .frame(minHeight: 440)
        .background(Color.fxBg)
        .onExitCommand { onClose() }
    }
}
