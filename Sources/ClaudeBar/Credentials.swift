import Foundation
import Security

/// Supplies the bearer token for the usage endpoint.
///
/// Source order, cheapest and least intrusive first:
///
///  1. ClaudeBar's own keychain item. Written by `set-token.sh` from
///     `claude setup-token`, with ClaudeBar on its ACL, so reading it never
///     prompts. This is the only source that stays quiet indefinitely.
///  2. `~/.claude/.credentials.json`, if a non-keychain install wrote one.
///  3. Claude Code's own keychain item. This works with no setup, but Claude
///     Code rotates that token about hourly and rewrites the item each time,
///     which resets its ACL and makes macOS ask again.
///
/// Whatever the source, the result is cached in memory until it expires, so a
/// 60-second poll does not mean a 60-second keychain hit.
///
/// ClaudeBar never refreshes or rewrites Claude Code's token - rotating it
/// would pull it out from under Claude Code.
enum Credentials {
    static let ownService = "com.jorikschellekens.claudebar"
    private static let claudeCodeService = "Claude Code-credentials"

    /// Long-lived tokens carry no expiry, so re-check occasionally in case the
    /// user replaced one.
    private static let opaqueTokenTTL: TimeInterval = 12 * 3600

    /// Refresh a little before the real expiry to avoid racing a rotation.
    private static let expiryMargin: TimeInterval = 120

    enum Failure: Error, LocalizedError {
        case notFound
        case keychainDenied(OSStatus)
        case malformed

        var errorDescription: String? {
            switch self {
            case .notFound: return "not signed in"
            case .keychainDenied: return "keychain denied"
            case .malformed: return "bad credentials"
            }
        }
    }

    private struct Cached {
        let token: String
        let goodUntil: Date
    }

    private static let lock = NSLock()
    // Every access below is inside `lock`.
    nonisolated(unsafe) private static var cached: Cached?

    /// Drop the cache so the next call goes back to the source. Call this when
    /// the API rejects the token.
    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    static func token() throws -> String {
        lock.lock()
        if let c = cached, c.goodUntil > Date() {
            lock.unlock()
            return c.token
        }
        lock.unlock()

        let (token, goodUntil) = try resolve()

        lock.lock()
        cached = Cached(token: token, goodUntil: goodUntil)
        lock.unlock()
        return token
    }

    private static func resolve() throws -> (String, Date) {
        // 1. Our own item - a bare token string, no envelope.
        if let data = try? keychainData(service: ownService),
           let raw = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return (raw, Date().addingTimeInterval(opaqueTokenTTL))
        }

        // 2. Credentials file.
        if let data = fileData(), let oauth = try? decode(data) {
            return (oauth.accessToken, expiry(of: oauth))
        }

        // 3. Claude Code's item. Let a denial surface - it is the one the user
        //    can act on.
        guard let data = try keychainData(service: claudeCodeService) else {
            throw Failure.notFound
        }
        let oauth = try decode(data)
        return (oauth.accessToken, expiry(of: oauth))
    }

    private static func expiry(of oauth: OAuth) -> Date {
        guard let ms = oauth.expiresAt else {
            return Date().addingTimeInterval(opaqueTokenTTL)
        }
        let real = Date(timeIntervalSince1970: ms / 1000)
        return max(Date().addingTimeInterval(30), real.addingTimeInterval(-expiryMargin))
    }

    // MARK: - Decoding

    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
        let subscriptionType: String?
    }

    private struct Envelope: Decodable {
        let claudeAiOauth: OAuth
    }

    private static func decode(_ data: Data) throws -> OAuth {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw Failure.malformed
        }
        return env.claudeAiOauth
    }

    // MARK: - Sources

    private static func keychainData(service: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            return out as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychainDenied(status)
        }
    }

    private static func fileData() -> Data? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: path)
    }
}
