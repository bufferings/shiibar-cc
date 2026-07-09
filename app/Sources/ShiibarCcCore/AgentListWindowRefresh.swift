// Agents window periodic refresh tuning (DESIGN.md §4.5 "the agent list window", M26
// T3): while the "Open as Window" list is visible, its elapsed-time base is
// re-taken once a minute (display is minute-granularity, so no per-second
// ticking is needed — the dropdown's "reopen to refresh" idea, automated
// because this container lives longer). The actual `Timer` that drives this
// lives in `AgentsWindowViewModel` (AppKit/SwiftUI, not unit-testable in
// this target) — this type holds just the one tunable number so it has one
// place of truth and can be checked against DESIGN.md §4.5 in a test, the
// same pattern as `PeriodicReconcile`.

import Foundation

public enum AgentListWindowRefresh {
    /// §4.5: re-take the Agents window's elapsed-time base every 60
    /// seconds while the window is visible.
    public static let intervalSeconds: Double = 60
}
