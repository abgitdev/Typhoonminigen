import Foundation
import Security

/// Resolves the HuggingFace token for the gated Klein 9B model.
/// Priority: env var → Keychain. S-4: stored in Keychain, not plaintext UserDefaults.
enum HFToken {
    // Kept for migration lookup only; no longer written.
    static let userDefaultsKey = "hfToken"

    private static let service = "com.personal.typhoonminigen"
    private static let account = "hfToken"

    static func current(for tier: ModelTier) -> String? {
        // The APP never passes the token for ungated tiers (Klein 4B, Apache). NB the
        // engine itself setenv()s HF_TOKEN after any 9B flow, so later in-process requests
        // to huggingface.co may still carry it — TLS-only, never visible to repo owners.
        guard tier.isGated else { return nil }
        if let env = ProcessInfo.processInfo.environment["HF_TOKEN"], !env.isEmpty {
            return env
        }
        // One-time migration from the old plaintext UserDefaults storage. Only drop the
        // plaintext copy once the Keychain write is CONFIRMED — otherwise a failed write
        // would lose the token. Either way we return the in-hand value for this session.
        if let legacy = UserDefaults.standard.string(forKey: userDefaultsKey), !legacy.isEmpty {
            if save(legacy) { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }
            return legacy
        }
        if let token = load() { return token }
        return nil
    }

    /// Returns true only if the token is actually persisted to (or removed from) the Keychain,
    /// so callers can report honest success instead of an unconditional "Saved".
    @discardableResult
    static func save(_ token: String) -> Bool {
        if token.isEmpty { delete(); return true }
        guard let data = token.data(using: .utf8) else { return false }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String = service) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func load(service: String = service) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }
}
