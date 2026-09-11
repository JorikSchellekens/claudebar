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
    /// The pace marker is on by default; it costs no width, only a hairline.
    @Published var showPace = true {
        didSet { UserDefaults.standard.set(showPace, forKey: "showPace") }
    }

    let spans = WindowSpans()

    private let cacheKey = "lastUsage"

    init() {
        if let raw = UserDefaults.standard.string(forKey: "displayMode"),
           let m = DisplayMode(rawValue: raw) {
            mode = m
        }
        if UserDefaults.standard.object(forKey: "showPace") != nil {
            showPace = UserDefaults.standard.bool(forKey: "showPace")
        }
        // Show the last known numbers immediately rather than an empty bar,
        // which matters most on a restart into a rate limit.
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(Usage.self, from: data) {
            usage = cached
            spans.learn(cached)
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
                spans.learn(fresh)
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

/// The stretch between the fill edge and the pace mark, when that stretch is
/// overspend: one step worse than the meter's own colour, so it warns without
/// inventing a fourth hue.
///
/// Nil once the bar is already red, where there is no worse step to take. A
/// lighter red would have been the only room left, and on a nearly-spent
/// window that stretch is most of the bar - so the meter would have gone
/// *paler* exactly when it matters most. The notch alone carries it there.
func paceOverColor(remaining: Int) -> Color? {
    switch remaining {
    case ..<10: return nil
    case ..<30: return Color(red: 0.95, green: 0.31, blue: 0.31)
    default: return Color(red: 0.97, green: 0.68, blue: 0.20)
    }
}

struct MeterView: View {
    let limit: Limit
    let mode: DisplayMode
    /// Ticks once a second so the countdown stays honest.
    let now: Date
    /// Where the fill edge would be if this window were spent evenly. Nil when
    /// the limit has no reset time, or when the marker is switched off.
    let pace: Pace?

    /// The number shown. The bar always fills in the same direction as it.
    private var value: Int { mode == .left ? limit.remaining : limit.percent }

    private var color: Color { meterColor(remaining: limit.remaining) }

    private static let barWidth: CGFloat = 46
    private static let barHeight: CGFloat = 6

    /// x of the fill edge, and of the pace mark, in bar coordinates.
    private var fillX: CGFloat { Self.barWidth * CGFloat(min(max(value, 0), 100)) / 100 }
    private var markX: CGFloat? {
        // In the first sliver of a window the mark says nothing - and it would
        // land on the end cap, where it just eats the fill.
        guard let pace, pace.elapsed >= 0.03 else { return nil }
        return Self.barWidth * CGFloat(pace.markerFraction(mode: mode))
    }

    /// The gap between the two, when the fill edge is on the wrong side of the
    /// mark. Overspend shows as filled bar past the mark in "used" mode and as
    /// a shortfall of bar before it in "left" mode; either way it is the same
    /// interval, so one span covers both.
    private var overSpan: (x: CGFloat, width: CGFloat)? {
        guard let pace, pace.deltaPoints > 0, let markX else { return nil }
        let lo = min(fillX, markX), hi = max(fillX, markX)
        guard hi - lo >= 1 else { return nil }
        return (lo, hi - lo)
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(limit.label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            meter

            Text("\(value)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                // Fixed field: the numbers change every poll, and without this
                // every meter to the right of one shifts when 9% becomes 10%.
                .lineLimit(1)
                .frame(width: 33, alignment: .trailing)

            if let r = limit.resetsAt {
                Text(countdown(to: r, now: now))
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
                    .frame(width: 42, alignment: .leading)
            }
        }
        .help(tooltip)
    }

    private var meter: some View {
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                Capsule()
                    .fill(color)
                    .frame(width: max(4, fillX))
                if let overSpan, let overColor = paceOverColor(remaining: limit.remaining) {
                    // In "used" mode this stretch is bar you have actually
                    // burnt, so it is painted solid. In "left" mode it is
                    // headroom you should still have and do not - a ghost of
                    // the shortfall, and painting it solid would read as spend.
                    Rectangle()
                        .fill(overColor)
                        .opacity(mode == .used ? 1 : 0.32)
                        .frame(width: overSpan.width)
                        .offset(x: overSpan.x)
                }
                if let markX {
                    // Punched out rather than painted over, so the notch is the
                    // pill's own material and reads the same against track,
                    // fill, and overspend alike, in either appearance.
                    Capsule()
                        .fill(Color.black)
                        .frame(width: 3, height: Self.barHeight)
                        .offset(x: notch(markX))
                        .blendMode(.destinationOut)
                }
            }
            .frame(width: Self.barWidth, height: Self.barHeight)
            .compositingGroup()
            .clipShape(Capsule())

            if let markX {
                Capsule()
                    .fill(Color.primary.opacity(0.42))
                    .frame(width: 1, height: Self.barHeight + 3)
                    .offset(x: notch(markX) + 1)
            }
        }
        .frame(width: Self.barWidth, height: Self.barHeight)
    }

    /// Keep the notch clear of both end caps, where a capsule has no width to
    /// spare and the mark would just chew a corner off.
    private func notch(_ x: CGFloat) -> CGFloat {
        min(max(x - 1.5, 2), Self.barWidth - 5)
    }

    private var tooltip: String {
        var s = "\(limit.label): \(limit.remaining)% left, \(limit.percent)% used"
        if let r = limit.resetsAt {
            s += ", resets \(r.formatted(date: .abbreviated, time: .shortened))"
        }
        if let pace {
            let elapsed = Int((pace.elapsed * 100).rounded())
            let delta = Int(pace.deltaPoints.rounded())
            s += "\n\(elapsed)% of the window gone, \(limit.percent)% of it spent"
            if delta > 0 {
                s += " - \(delta) points ahead of an even burn"
            } else if delta < 0 {
                s += " - \(-delta) points behind an even burn"
            } else {
                s += " - exactly on an even burn"
            }
            if let projected = pace.projected {
                s += "\nat this rate: \(Int(projected.rounded()))% by reset"
            }
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
        // Floor is legibility, not invisibility - the bar still has to be
        // readable at a glance when everything is fine.
        switch worst {
        case ..<50: return 0.6
        case 80...: return 1
        default: return 0.6 + Double(worst - 50) / 30 * 0.4
        }
    }

    private var staleHelp: String {
        guard let usage = store.usage else { return "ClaudeBar" }
        var s = "updated \(usage.fetchedAt.formatted(date: .omitted, time: .standard))"
        if let err = store.errorText { s += " - last poll failed: \(err)" }
        return s
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("claude")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .kerning(0.2)
                .foregroundStyle(store.stale ? Color(red: 0.97, green: 0.68, blue: 0.20) : .secondary)
                .opacity(store.loading ? 0.45 : 1)
                .help(staleHelp)

            if let usage = store.usage {
                // Last good numbers stay up through a failed poll; the label
                // turns amber once they are old enough to distrust.
                ForEach(usage.limits) { limit in
                    MeterView(
                        limit: limit,
                        mode: store.mode,
                        now: now,
                        pace: store.showPace ? store.spans.pace(for: limit, now: now) : nil
                    )
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
        // A capsule eats its own corners, so the end caps need more room than
        // a rectangle would.
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .fixedSize()
        .opacity(restingOpacity)
        .animation(.easeInOut(duration: 0.35), value: restingOpacity)
        .onReceive(tick) { now = $0 }
        .onHover { hovering = $0 }
        // Clicks are handled by BarHostingView, not here - see the note there.
    }
}
