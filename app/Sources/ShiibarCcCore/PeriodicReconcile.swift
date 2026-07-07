// Periodic reconcile tuning (DESIGN.md §4.5/§8.22/§9): self-repairs status
// drift from missed hooks (e.g. "stuck on working") without waiting for a
// manual Rescan or a daemon reconnect. The actual `NSBackgroundActivityScheduler`
// that drives the timer lives in AppState (AppKit-only, not unit-testable in
// this target) — this type holds just the two tunable numbers so they have
// one place of truth and can be checked against DESIGN.md §9 in a test.

import Foundation

public enum PeriodicReconcile {
    /// §9: periodic reconcile interval, ~60 seconds
    /// (`NSBackgroundActivityScheduler.interval`).
    public static let intervalSeconds: Double = 60
    /// §9: periodic reconcile tolerance window, 30 seconds
    /// (`NSBackgroundActivityScheduler.tolerance`).
    public static let toleranceSeconds: Double = 30
}
