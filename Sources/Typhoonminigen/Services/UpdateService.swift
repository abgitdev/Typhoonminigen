import Foundation

/// Update check against the public GitHub Releases API, run on launch and lightly
/// throttled (at most one network request per hour). Strictly opt-in:
/// `updateCheckEnabled` is ABSENT until the user decides — never write a default, and
/// absent means disabled (the key may also hold an explicit false written by the
/// tutorial checkbox or System → MAINTENANCE). A found release is remembered in
/// UserDefaults so the pill re-appears every launch until dismissed or installed,
/// without re-hitting the network inside the throttle window. The only request is an
/// unauthenticated GET to api.github.com; nothing about the user or machine is sent
/// beyond the standard headers.
enum UpdateService {
    struct UpdateInfo: Sendable {
        let version: String   // stripped of the leading "v", e.g. "0.46"
        let url: URL          // release page (html_url) to open in the browser
    }

    // UserDefaults keys (raw literals on purpose — surveyable with `defaults read`).
    static let enabledKey   = "updateCheckEnabled"     // Bool; absent = disabled
    static let lastCheckKey = "lastUpdateCheckDate"    // TimeInterval since 1970
    static let etagKey      = "lastUpdateETag"         // weak ETag, sent back verbatim
    static let dismissedKey = "dismissedUpdateTag"     // version the user dismissed
    static let foundTagKey  = "lastFoundUpdateTag"     // last newer release tag found
    static let foundURLKey  = "lastFoundUpdateURL"     // its html_url, re-shown each launch

    private static let endpoint = URL(string:
        "https://api.github.com/repos/abgitdev/Typhoonminigen/releases/latest")!
    // ~1h: re-checks on every launch in normal use, but never spams GitHub on rapid relaunches.
    private static let checkInterval: TimeInterval = 3_600

    /// True only if the key exists AND is true (absent key = opt-in not given).
    static var isEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: enabledKey) != nil && d.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    /// Remember a dismissed version so its pill never re-appears for the same release.
    static func dismiss(version: String) {
        UserDefaults.standard.set(version, forKey: dismissedKey)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Returns the release to advertise, or nil. A release found earlier is re-surfaced
    /// from UserDefaults on every launch — until dismissed, or stale because the app
    /// caught up — even inside the network throttle window. The throttle stamps the ATTEMPT
    /// (failures and 404s must not retry every launch). Every failure (404 while the
    /// repo is private, 403/429 rate limit, network error) is silent — the check must
    /// never alarm — and falls back to the cached candidate.
    static func checkIfDue() async -> UpdateInfo? {
        guard isEnabled else { return nil }  // disabled = zero side effects below
        let defaults = UserDefaults.standard

        let cachedCandidate: UpdateInfo? = {
            guard let tag = defaults.string(forKey: foundTagKey),
                  let raw = defaults.string(forKey: foundURLKey),
                  let url = URL(string: raw) else { return nil }
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isNewer(remote: remote, local: AppVersion.current) else {
                // Stale after the user updates — forget it.
                defaults.removeObject(forKey: foundTagKey)
                defaults.removeObject(forKey: foundURLKey)
                return nil
            }
            let dismissed = defaults.string(forKey: dismissedKey)
            if remote == dismissed || tag == dismissed { return nil }
            return UpdateInfo(version: remote, url: url)
        }()

        let last = defaults.double(forKey: lastCheckKey)
        if last > 0 && Date().timeIntervalSince1970 - last < checkInterval {
            return cachedCandidate
        }
        defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("Typhoonminigen/" + AppVersion.current, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag = defaults.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let status: Int
        let newETag: String?
        do {
            let (d, response) = try await URLSession.shared.data(for: request)
            data = d
            let http = response as? HTTPURLResponse
            status = http?.statusCode ?? 0
            newETag = http?.value(forHTTPHeaderField: "ETag")
        } catch {
            AppLog.info("Update check: network error — \(error.localizedDescription)")
            return cachedCandidate
        }

        switch status {
        case 200:
            if let newETag { defaults.set(newETag, forKey: etagKey) }
            guard let release = try? JSONDecoder().decode(Release.self, from: data),
                  let url = URL(string: release.htmlURL) else {
                AppLog.info("Update check: could not parse the release response")
                return cachedCandidate
            }
            let tag = release.tagName
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isNewer(remote: remote, local: AppVersion.current) else {
                defaults.removeObject(forKey: foundTagKey)
                defaults.removeObject(forKey: foundURLKey)
                AppLog.info("Update check: up to date (latest \(tag))")
                return nil
            }
            defaults.set(tag, forKey: foundTagKey)
            defaults.set(release.htmlURL, forKey: foundURLKey)
            let dismissed = defaults.string(forKey: dismissedKey)
            if remote == dismissed || tag == dismissed {
                AppLog.info("Update check: \(tag) available but dismissed earlier")
                return nil
            }
            AppLog.info("Update check: \(tag) is available")
            return UpdateInfo(version: remote, url: url)
        case 304:
            AppLog.info("Update check: up to date (304)")
            return cachedCandidate
        default:
            AppLog.info("Update check: HTTP \(status) — skipped")
            return cachedCandidate
        }
    }

    /// Component-wise numeric compare: "0.10" > "0.9", "1.0" == "1.0.0". All-zero remote
    /// tags (unparseable junk like "latest") are never treated as an update.
    static func isNewer(remote: String, local: String) -> Bool {
        var r = remote.split(separator: ".").map { Int($0) ?? 0 }
        var l = local.split(separator: ".").map { Int($0) ?? 0 }
        guard r.contains(where: { $0 > 0 }) else { return false }
        while r.count < l.count { r.append(0) }
        while l.count < r.count { l.append(0) }
        for (a, b) in zip(r, l) where a != b { return a > b }
        return false
    }
}
