import SwiftUI

/// Percent used, matching Claude Code's own `/usage`. Switchable to percent
/// left from the right-click menu; the tooltip always states both.
enum DisplayMode: String {
    case left, used

    var toggled: DisplayMode { self == .left ? .used : .left }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var usage: Usage?
    @Published var errorText: String?
    @Published var loading = false
    @Published var mode: DisplayMode = .used {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "displayMode") }
    }

    private let cacheKey = "lastUsage"

    init() {
        if let raw = UserDefaults.standard.string(forKey: "displayMode"),
           let m = DisplayMode(rawValue: raw) {
            mode = m
        }
        // Show the last known numbers immediately rather than an empty bar,
        // which matters most on a restart into a rate limit.
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(Usage.self, from: data) {
            usage = cached
        }
    }

    /// Called after every successful fetch, so the threshold notifier can look
    /// at the same data the bar just rendered.
    var onUsage: ((Usage) -> Void)?

    /// Double-click sends the bar back to bottom centre.
    var onResetPosition: (() -> Void)?

    /// A click asks for fresh data, but the endpoint rate-limits, so ignore
    /// clicks that land on numbers which are already current.
    func manualRefresh() {
        if let usage, Date().timeIntervalSince(usage.fetchedAt) < 30 { return }
        refresh()
    }

    private var timer: Timer?

    /// The windows are measured in hours and days, and the endpoint rate-limits,
    /// so a tight poll buys nothing and costs 429s.
    private let interval: TimeInterval = 300
    private let maxBackoff: TimeInterval = 1800
    private var backoff: TimeInterval = 300

    /// True once the displayed numbers are old enough to distrust.
    var stale: Bool {
        guard let usage else { return false }
        return Date().timeIntervalSince(usage.fetchedAt) > interval * 3
    }

    /// Don't spend a request just because the app restarted. A cached reading
    /// younger than the poll interval is good enough to open with, which keeps
    /// a crash loop or a run of reinstalls from burning the endpoint's quota.
    func start() {
        if let usage, Date().timeIntervalSince(usage.fetchedAt) < interval {
            scheduleNext(interval - Date().timeIntervalSince(usage.fetchedAt))
        } else {
            refresh()
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task { @MainActor in
            do {
                let fresh = try await UsageClient.fetch()
                usage = fresh
                errorText = nil
                backoff = interval
                if let data = try? JSONEncoder().encode(fresh) {
                    UserDefaults.standard.set(data, forKey: cacheKey)
                }
                onUsage?(fresh)
            } catch {
                // Keep the last good numbers on screen; a failed poll is not a
                // reason to blank the bar. `stale` marks them if it persists.
                errorText = (error as? LocalizedError)?.errorDescription ?? "offline"
                if case UsageError.rateLimited(let retryAfter) = error, let retryAfter {
                    backoff = min(max(retryAfter, interval), maxBackoff)
                } else {
                    backoff = min(backoff * 2, maxBackoff)
                }
            }
            loading = false
            scheduleNext(errorText == nil ? interval : backoff)
        }
    }

    private func scheduleNext(_ delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

/// Countdown like "2h 14m" / "3d 4h" / "8m".
func countdown(to date: Date, now: Date = Date()) -> String {
    let s = Int(date.timeIntervalSince(now))
    if s <= 0 { return "now" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func meterColor(remaining: Int) -> Color {
    switch remaining {
    case ..<10: return Color(red: 0.95, green: 0.31, blue: 0.31)
    case ..<30: return Color(red: 0.97, green: 0.68, blue: 0.20)
    default: return Color(red: 0.36, green: 0.80, blue: 0.55)
    }
}

struct MeterView: View {
    let limit: Limit
    let mode: DisplayMode
    /// Ticks once a second so the countdown stays honest.
    let now: Date

    /// The number shown. The bar always fills in the same direction as it.
    private var value: Int { mode == .left ? limit.remaining : limit.percent }

    private var color: Color { meterColor(remaining: limit.remaining) }

    var body: some View {
        HStack(spacing: 6) {
            Text(limit.label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                Capsule()
                    .fill(color)
                    .frame(width: max(2, 46 * CGFloat(value) / 100))
            }
            .frame(width: 46, height: 5)

            Text("\(value)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)

            if let r = limit.resetsAt {
                Text(countdown(to: r, now: now))
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .help(tooltip)
    }

    private var tooltip: String {
        var s = "\(limit.label): \(limit.remaining)% left, \(limit.percent)% used"
        if let r = limit.resetsAt {
            s += ", resets \(r.formatted(date: .abbreviated, time: .shortened))"
        }
        return s
    }
}

struct BarView: View {
    @ObservedObject var store: UsageStore
    @State private var now = Date()
    @State private var hovering = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Recede while there is nothing to report, surface as usage climbs.
    /// Hovering always brings it back to full.
    private var restingOpacity: Double {
        if hovering { return 1 }
        guard let usage = store.usage else { return 1 }
        let worst = usage.limits.map(\.percent).max() ?? 0
        switch worst {
        case ..<50: return 0.4
        case 80...: return 1
        default: return 0.4 + Double(worst - 50) / 30 * 0.6
        }
    }

    private var staleHelp: String {
        guard let usage = store.usage else { return "ClaudeBar" }
        var s = "updated \(usage.fetchedAt.formatted(date: .omitted, time: .standard))"
        if let err = store.errorText { s += " - last poll failed: \(err)" }
        return s
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("claude")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(store.stale ? Color(red: 0.97, green: 0.68, blue: 0.20) : .secondary)
                .opacity(store.loading ? 0.45 : 1)
                .help(staleHelp)

            if let usage = store.usage {
                // Last good numbers stay up through a failed poll; the label
                // turns amber once they are old enough to distrust.
                ForEach(usage.limits) { limit in
                    MeterView(limit: limit, mode: store.mode, now: now)
                }
            } else if let err = store.errorText {
                Text(err)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color(red: 0.95, green: 0.31, blue: 0.31))
            } else {
                Text("loading")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .fixedSize()
        .opacity(restingOpacity)
        .animation(.easeInOut(duration: 0.35), value: restingOpacity)
        .onReceive(tick) { now = $0 }
        .onHover { hovering = $0 }
        // Double-click must be declared first, or the single-click gesture
        // swallows it.
        .onTapGesture(count: 2) { store.onResetPosition?() }
        .onTapGesture { store.manualRefresh() }
    }
}
