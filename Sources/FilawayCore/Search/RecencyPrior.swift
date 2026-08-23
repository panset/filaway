import Foundation

/// A mild preference for notes edited recently (plan §1 "hybrid ranking").
///
/// This is the *soft* half of FR-5.3. When the query names a date,
/// ``TemporalQuery/range`` filters hard and this prior is off; when it says
/// "recently", or says nothing at all, a note touched this morning should edge
/// out an equally relevant one from eighteen months ago — but only just.
/// Recency dominating relevance was the failure mode the plan's own synthetic
/// corpus warns about ("Ranking improved once recency stopped dominating the
/// score"), so the boost is a bounded multiplier, not an additive term.
public struct RecencyPrior: Sendable, Equatable {
    /// Age at which the boost has decayed to half of ``maxBoost``.
    public var halfLife: TimeInterval
    /// Boost applied to a note modified *now*: `1 + maxBoost`.
    ///
    /// Read this against the thing it multiplies. Fused scores are RRF sums,
    /// and adjacent ranks there differ by about **1.6%** (`1/61` vs `1/62`), so
    /// a "+20%" ceiling is not a nudge — it is worth roughly twelve rank
    /// positions, and M3-07 measured it dragging note top-1 from 90% down to
    /// 78% on the development corpus. The ceilings below are quarter of what
    /// ADR-040 first shipped, which is where the prior goes back to breaking
    /// ties instead of deciding them (ADR-041).
    public var maxBoost: Double

    public init(halfLife: TimeInterval = 30 * 86_400, maxBoost: Double = 0.05) {
        self.halfLife = max(1, halfLife)
        self.maxBoost = max(0, maxBoost)
    }

    /// The default: a 30-day half-life and at most +5% — about three rank
    /// positions of RRF, which is a tie-break and not a re-sort.
    public static let `default` = RecencyPrior()

    /// No prior at all — used whenever a hard date range applies, because
    /// inside the range every note is equally "when the user meant".
    public static let none = RecencyPrior(maxBoost: 0)

    /// What "recently" buys: a much sharper 7-day curve and a bigger ceiling,
    /// still short of overturning a large relevance gap.
    public static let recent = RecencyPrior(
        halfLife: TemporalQueryParser.recentWindow, maxBoost: 0.15
    )

    /// A prior with a caller-chosen window, for
    /// ``TemporalQuery/boostWindow``.
    public static func window(_ seconds: TimeInterval, maxBoost: Double = 0.15) -> RecencyPrior {
        RecencyPrior(halfLife: seconds, maxBoost: maxBoost)
    }

    /// `1 ... 1 + maxBoost`. A note modified in the future (clock skew, a
    /// copied mtime) is treated as modified now, never more.
    public func multiplier(for modified: Date, now: Date) -> Double {
        guard maxBoost > 0 else { return 1 }
        let age = max(0, now.timeIntervalSince(modified))
        return 1 + maxBoost * exp(-.ln2 * age / halfLife)
    }
}

private extension Double {
    static let ln2 = 0.693_147_180_559_945_3
}
