import Foundation
import UserNotifications

/// Notifies once when a window crosses 80%, again at 95%, and re-arms when
/// that window resets. Nothing is shown while usage is unremarkable.
@MainActor
final class Notifier {
    static let thresholds = [95, 80]

    private var authorized = false
    /// An ad-hoc signed bundle is not always allowed to post through
    /// UserNotifications, so keep a path that always works.
    private var useOsascript = false

    private struct Mark: Codable {
        var threshold: Int
        var resetsAt: Date?
    }

    private var marks: [String: Mark] = [:]
    private let defaultsKey = "notifyMarks"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Mark].self, from: data) {
            marks = decoded
        }
    }

    func prepare() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.authorized = granted && error == nil
                    self.useOsascript = !self.authorized
                }
            }
    }

    func evaluate(_ usage: Usage) {
        for limit in usage.limits {
            let previous = marks[limit.id]

            // A new window means a clean slate.
            if let previous, previous.resetsAt != limit.resetsAt {
                marks[limit.id] = Mark(threshold: 0, resetsAt: limit.resetsAt)
            }

            let crossed = Notifier.thresholds.first { limit.percent >= $0 } ?? 0
            let last = marks[limit.id]?.threshold ?? 0

            if crossed > last {
                post(
                    title: "Claude usage at \(limit.percent)%",
                    body: "\(windowName(limit)) - \(limit.remaining)% left, resets in "
                        + countdown(to: limit.resetsAt ?? Date())
                )
            }
            // Also track downward so a dropped threshold can fire again later.
            if crossed != last {
                marks[limit.id] = Mark(threshold: crossed, resetsAt: limit.resetsAt)
            }
        }
        persist()
    }

    private func windowName(_ limit: Limit) -> String {
        switch limit.kind {
        case "session": return "Session window"
        case "weekly_all": return "Weekly, all models"
        case "weekly_scoped": return "Weekly, \(limit.modelName ?? "scoped")"
        default: return limit.label
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(marks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func post(title: String, body: String) {
        if useOsascript {
            postViaOsascript(title: title, body: body)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.useOsascript = true
                self?.postViaOsascript(title: title, body: body)
            }
        }
    }

    private func postViaOsascript(title: String, body: String) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = "display notification \(quoted(body)) with title \(quoted(title))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
