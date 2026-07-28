import Foundation
import Security

/// Reads the OAuth access token Claude Code stores for the logged-in account.
///
/// Claude Code keeps it in the login keychain under the generic-password service
/// "Claude Code-credentials". Some installs (and Linux-style setups) instead keep
/// a plain file at ~/.claude/.credentials.json, so we fall back to that.
///
/// We never refresh the token ourselves - refreshing would rotate it out from
/// under Claude Code. When it expires we just re-read; Claude Code refreshes it
/// on its own and we pick up the new value.
enum Credentials {
    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
        let subscriptionType: String?
    }

    private struct Envelope: Decodable {
        let claudeAiOauth: OAuth
    }

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

    static func load() throws -> OAuth {
        if let data = try keychainData() {
            return try decode(data)
        }
        if let data = fileData() {
            return try decode(data)
        }
        throw Failure.notFound
    }

    private static func decode(_ data: Data) throws -> OAuth {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw Failure.malformed
        }
        return env.claudeAiOauth
    }

    private static func keychainData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
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
