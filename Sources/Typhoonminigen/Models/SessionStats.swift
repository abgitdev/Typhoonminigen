import Foundation
import Observation

/// Lightweight, app-lifetime counters surfaced in the status bar (uptime, generations run).
@MainActor
@Observable
final class SessionStats {
    let launchedAt = Date()
    var generationCount = 0

    /// "HH:MM:SS" since launch — recomputed by the caller against a ticking clock.
    func uptimeString(now: Date = Date()) -> String {
        let secs = Int(now.timeIntervalSince(launchedAt))
        return String(format: "%02d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
    }
}
