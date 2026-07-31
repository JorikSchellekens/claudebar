import Foundation
import Security

/// Supplies the bearer token for the usage endpoint.
///
/// Source order:
///
///  1. `CLAUDEBAR_TOKEN` in the environment, for one-off runs from a shell.
///  2. `~/.config/claudebar/token` - a bare token on one line, if you have one
///     that the usage endpoint accepts. Reading it never prompts.
///  3. `~/.claude/.credentials.json`, on installs that keep credentials in a
///     file rather than the keychain.
///  4. Claude Code's keychain item. This is the one that actually works: it is
///     the only token the usage endpoint accepts, and Claude Code keeps it
///     fresh.
///
/// macOS asks for authorization the first time ClaudeBar reads that item.
/// Click "Always Allow" and it stops asking - Claude Code's hourly refresh
/// writes with `security add-generic-password -U`, which preserves the item's
/// ACL, so rotation alone does not bring the prompt back.
///
/// What does bring it back is rebuilding ClaudeBar: `install.sh` re-signs
/// ad-hoc, the code hash changes, and the granted access no longer matches the
/// binary. So expect one prompt per reinstall, and none in between.
///
/// Whatever the source, the result is cached in memory until it expires, so a
/// 60-second poll does not mean a 60-second disk hit.
///
/// ClaudeBar never refreshes or rewrites Claude Code's token - rotating it
/// would pull it out from under Claude Code.
enum Credentials {
    /// A bare token on one line, if you choose to place one here.
    static let tokenPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/claudebar/token")

    /// Long-lived tokens carry no expiry, so re-check occasionally in case the
    /// user replaced one.
    private static let opaqueTokenTTL: TimeInterval = 12 * 3600

    /// Refresh a little before the real expiry to avoid racing a rotation.
    private static let expiryMargin: TimeInterval = 120

    private static let claudeCodeService = "Claude Code-credentials"

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
        // 1. Environment.
        if let raw = ProcessInfo.processInfo.environment["CLAUDEBAR_TOKEN"].map(clean),
           !raw.isEmpty {
            return (raw, Date().addingTimeInterval(opaqueTokenTTL))
        }

        // 2. Our own token file - a bare token, no envelope.
        if let text = try? String(contentsOf: tokenPath, encoding: .utf8) {
            let raw = clean(text)
            if !raw.isEmpty {
                return (raw, Date().addingTimeInterval(opaqueTokenTTL))
            }
        }

        // 3. Claude Code's credentials file, where there is one.
        if let data = credentialsFileData(), let oauth = try? decode(data) {
            return (oauth.accessToken, expiry(of: oauth))
        }

        // 4. Claude Code's keychain item. Let a denial surface - it is the one
        //    the user can act on.
        guard let data = try keychainData(service: claudeCodeService) else {
            throw Failure.notFound
        }
        let oauth = try decode(data)
        return (oauth.accessToken, expiry(of: oauth))
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func credentialsFileData() -> Data? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: path)
    }
}
