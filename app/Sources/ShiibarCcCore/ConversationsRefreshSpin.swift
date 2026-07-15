// Rotation discipline for the Conversations ⟳ refresh button (DESIGN.md
// §4.6/§9/§8.44). The spin's phase is anchored to the refresh START time,
// not wall-clock time, so it always begins upright (0°). When the run ends
// the arrow keeps turning to the first whole-turn boundary at or after
// max(run end, one turn), so the switch back to the static glyph always
// lands at angle zero — no visible jump. The view (a TimelineView in
// ShiibarCcApp) reads these numbers; the numbers and the stop rule are
// pinned here by tests.

import Foundation

public enum ConversationsRefreshSpin {
    /// §9: 0.6 seconds per turn.
    public static let periodSeconds: Double = 0.6

    /// Rotation angle in degrees at `elapsedSeconds` after the spin started.
    /// Always 0 at elapsed 0 (starts upright — §8.44) and advances one full
    /// turn (360°) every `periodSeconds`.
    public static func angleDegrees(elapsedSeconds: Double) -> Double {
        let turns = elapsedSeconds / periodSeconds
        return turns.truncatingRemainder(dividingBy: 1) * 360
    }

    /// The elapsed time (since start) at which the spin returns to rest. The
    /// run usually finishes in tens of milliseconds, so the arrow keeps
    /// turning to the first whole-turn boundary at or after max(run end, one
    /// turn): the switch to the static glyph always lands at angle zero and
    /// at least one full turn is shown (DESIGN.md §9/§8.44 — the §8.43
    /// one-turn minimum is subsumed here).
    public static func stopElapsedSeconds(runEndSeconds: Double) -> Double {
        let target = max(runEndSeconds, periodSeconds)
        // Round the turn count up to the next whole turn. A tiny epsilon
        // absorbs binary-float error so a run that ends exactly on a
        // boundary stops there instead of spinning one extra turn.
        let turns = (target / periodSeconds - 1e-9).rounded(.up)
        return turns * periodSeconds
    }

    /// Whether the button is still spinning at `elapsedSeconds`. While the
    /// run is in flight (`runEndSeconds` nil) the spin continues; once the
    /// run has ended it stops at the whole-turn boundary from
    /// `stopElapsedSeconds`. The button stays disabled for exactly this span.
    public static func isSpinning(elapsedSeconds: Double, runEndSeconds: Double?) -> Bool {
        guard let runEndSeconds else { return true }
        return elapsedSeconds < stopElapsedSeconds(runEndSeconds: runEndSeconds)
    }
}
