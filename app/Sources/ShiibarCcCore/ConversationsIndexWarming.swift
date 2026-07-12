// Conversations index warming cadence (DESIGN.md §4.6/§8.22/§9): the app
// kicks `conversations index` at launch and then roughly every 10 minutes
// so a `conversations search`'s catch-up stays small. No FSEvents watching
// (§4.6). The actual `NSBackgroundActivityScheduler` lives in AppState
// (AppKit, not unit-testable in this target) — this type holds just the two
// tunable numbers so they have one place of truth and can be checked against
// DESIGN.md §9 in a test, mirroring `PeriodicReconcile`.

import Foundation

public enum ConversationsIndexWarming {
    /// §9: index-warming interval, ~10 minutes
    /// (`NSBackgroundActivityScheduler.interval`).
    public static let intervalSeconds: Double = 600
    /// §9: index-warming tolerance window, 5 minutes
    /// (`NSBackgroundActivityScheduler.tolerance`).
    public static let toleranceSeconds: Double = 300
}
