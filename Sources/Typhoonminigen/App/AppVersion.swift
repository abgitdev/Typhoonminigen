import Foundation

/// Single source of truth for the app version. The UI reads it directly;
/// tools/bundle_app.sh greps these two lines to stamp Info.plist — bump them HERE only.
///
/// Two independent numbers, Apple-style:
///   • `current` — marketing version (CFBundleShortVersionString), changed for releases.
///   • `build`   — build number (CFBundleVersion), bumped +1 on every build.
/// The status-bar badge renders them as `VERSION <current> BUILD <build>`.
enum AppVersion {
    static let current = "1.0"
    static let build = "9"

    /// Badge text shown in the bottom status bar, e.g. "VERSION 1.0 BUILD 1".
    static var badge: String { "VERSION \(current) BUILD \(build)" }
}
