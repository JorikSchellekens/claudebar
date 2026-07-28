import SwiftUI

/// Claude Code's own `/usage` reports percent *used*. Showing percent *left*
/// next to it reads as a mismatch even though it is the same number, so the
/// mode is explicit in the UI and switchable from the right-click menu.
enum DisplayMode: String {
    case left, used

    var suffix: String { rawValue }
    var toggled: DisplayMode { self == .left ? .used : .left }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var usage: Usage?
    @Published var errorText: String?
    @Published var loading = false
    @Published var mode: DisplayMode = .left {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "displayMode") }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "displayMode"),
           let m = DisplayMode(rawValue: raw) {
            mode = m
        }
    }

    private var timer: Timer?

    /// The API buckets usage over hours and days, so a tight poll buys nothing.
    private let interval: TimeInterval = 60

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task { @MainActor in
            do {
                usage = try await UsageClient.fetch()
                errorText = nil
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? "offline"
            }
            loading = false
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

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Text("claude \(store.mode.suffix)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .opacity(store.loading ? 0.45 : 1)

            if let usage = store.usage {
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
        .onReceive(tick) { now = $0 }
        .onTapGesture { store.refresh() }
    }
}
