import Foundation

/// How far through a window we are, against how much of it we have spent.
///
/// The API hands us a percent used and a reset time, but never says how long
/// the window is - and without that there is no way to say whether 40% used is
/// early or late. So the span is learned (see `WindowSpans`) and everything
/// here is derived from it.
struct Pace {
    /// Fraction of the window that has gone by, 0...1.
    let elapsed: Double
    /// Fraction of the allowance spent, 0...1 (it can exceed 1 in principle).
    let used: Double

    /// Positive means burning faster than the clock: spent more of the
    /// allowance than of the window.
    var deltaPoints: Double { (used - elapsed) * 100 }

    /// Where this ends up at reset if the current rate holds. Meaningless in
    /// the first slice of a window, where one message reads as an infinite
    /// rate, so it is withheld until there is enough window behind us.
    var projected: Double? {
        guard elapsed >= 0.1 else { return nil }
        return min(999, used / elapsed * 100)
    }

    /// The mark on the meter: where the fill edge would sit if consumption
    /// were perfectly even. In "used" mode that is the elapsed fraction; in
    /// "left" mode the bar fills with what remains, so it mirrors.
    func markerFraction(mode: DisplayMode) -> Double {
        mode == .used ? elapsed : 1 - elapsed
    }
}

/// Nominal window lengths, used only until a longer one is measured.
///
/// These are the product's own windows - the labels literally read "5h" and
/// "Week" - not estimates of them.
private func nominalSpan(kind: String) -> TimeInterval {
    switch kind {
    case "session": return 5 * 3600
    default: return 7 * 86400
    }
}

/// Learns each window's length by watching it.
///
/// Time-to-reset is at its largest the moment a window opens, and that maximum
/// *is* the span, so the running maximum converges on the true length from
/// below and never overshoots it. Measuring it off the jump in `resets_at`
/// instead would be wrong: a session window starts at the first message after
/// the last one lapsed, so the gap between two resets is the span plus however
/// long you were idle.
@MainActor
final class WindowSpans {
    private var observed: [String: TimeInterval]
    private let key = "windowSpans"

    init() {
        observed = UserDefaults.standard.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
    }

    func learn(_ usage: Usage) {
        var changed = false
        for limit in usage.limits {
            guard let resets = limit.resetsAt else { continue }
            let ttr = resets.timeIntervalSince(usage.fetchedAt)
            guard ttr > 0 else { continue }
            if ttr > (observed[limit.id] ?? 0) {
                observed[limit.id] = ttr
                changed = true
            }
        }
        if changed { UserDefaults.standard.set(observed, forKey: key) }
    }

    func span(for limit: Limit) -> TimeInterval {
        max(observed[limit.id] ?? 0, nominalSpan(kind: limit.kind))
    }

    /// Nil when the limit carries no reset time, which leaves nothing to pace
    /// against.
    func pace(for limit: Limit, now: Date = Date()) -> Pace? {
        guard let resets = limit.resetsAt else { return nil }
        let span = span(for: limit)
        guard span > 0 else { return nil }
        let remaining = resets.timeIntervalSince(now)
        let elapsed = min(max(1 - remaining / span, 0), 1)
        return Pace(elapsed: elapsed, used: Double(limit.percent) / 100)
    }
}
