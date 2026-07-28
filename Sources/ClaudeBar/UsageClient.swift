import Foundation

/// One usage meter as reported by the API.
struct Limit: Identifiable, Equatable {
    let kind: String        // "session", "weekly_all", "weekly_scoped"
    let percent: Int        // percent *used*
    let severity: String    // "normal", "warning", ...
    let resetsAt: Date?
    let modelName: String?  // set for weekly_scoped

    var id: String { kind + (modelName ?? "") }

    /// Short label for the bar.
    var label: String {
        switch kind {
        case "session": return "5h"
        case "weekly_all": return "Week"
        case "weekly_scoped": return modelName ?? "Week*"
        default: return kind
        }
    }

    var remaining: Int { max(0, 100 - percent) }
}

struct Usage: Equatable {
    let limits: [Limit]
    let fetchedAt: Date
}

enum UsageError: Error, LocalizedError {
    case unauthorized
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "re-auth needed"
        case .http(let c): return "HTTP \(c)"
        case .malformed: return "bad response"
        }
    }
}

enum UsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async throws -> Usage {
        do {
            return try await attempt()
        } catch UsageError.unauthorized {
            // The cached token went stale early. Drop it and try the source once.
            Credentials.invalidate()
            return try await attempt()
        }
    }

    private static func attempt() async throws -> Usage {
        let token = try Credentials.token()

        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claudebar/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UsageError.malformed }
        guard http.statusCode == 200 else {
            throw http.statusCode == 401 ? UsageError.unauthorized : UsageError.http(http.statusCode)
        }
        return try parse(data)
    }

    /// The `limits` array is the API's own presentation model, so we lean on it
    /// rather than the older per-window top-level keys.
    static func parse(_ data: Data) throws -> Usage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["limits"] as? [[String: Any]]
        else { throw UsageError.malformed }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        let limits: [Limit] = raw.compactMap { entry in
            guard let kind = entry["kind"] as? String,
                  let percent = entry["percent"] as? NSNumber
            else { return nil }

            var resets: Date?
            if let s = entry["resets_at"] as? String {
                resets = iso.date(from: s) ?? isoPlain.date(from: s)
            }

            var model: String?
            if let scope = entry["scope"] as? [String: Any],
               let m = scope["model"] as? [String: Any] {
                model = m["display_name"] as? String
            }

            return Limit(
                kind: kind,
                percent: percent.intValue,
                severity: entry["severity"] as? String ?? "normal",
                resetsAt: resets,
                modelName: model
            )
        }

        guard !limits.isEmpty else { throw UsageError.malformed }
        return Usage(limits: limits, fetchedAt: Date())
    }
}
