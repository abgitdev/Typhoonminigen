import Foundation
import AppKit
@preconcurrency import UserNotifications

/// Plays a sound + posts a local notification when a generation queue finishes — multi-image
/// runs take many minutes and the user is usually in another app (or another room).
enum QueueNotifier {
    /// Without a delegate macOS suppresses banners while the app is frontmost — so a user
    /// watching the queue never saw them. Install once at launch (needs a real bundle).
    static func installDelegate() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = ForegroundBannerDelegate.shared
    }

    static func notifyFinished(count: Int) {
        NSSound(named: "Glass")?.play()
        // Local notifications need a real bundle (we always run from the .app, so this holds).
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Typhoonminigen"
            content.body = count == 1 ? "Image ready." : "Queue finished — \(count) images ready."
            UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Presents queue-finished notifications as a banner+sound even when the app is active.
/// Stateless, so the shared instance is safe to touch from any thread.
final class ForegroundBannerDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ForegroundBannerDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
