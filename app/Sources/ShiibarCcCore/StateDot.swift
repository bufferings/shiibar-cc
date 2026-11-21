// The two state colors (DESIGN.md §3.1, §9 "state colors"): orange for
// waiting (stopped, waiting for the user's action) and the accent color for
// unreviewed (not yet looked at). Wherever one dot stands for several
// sessions — the tray icon's dot (§4.5 "visual source of truth") and the
// closed Running heading's mark (§4.5 "collapsing sections") — waiting
// takes priority, because a waiting session has to be dealt with first even
// when it has been looked at.

import Foundation

/// Which color a dot that stands for several sessions shows.
public enum StateDot: Equatable, Sendable {
    /// At least one session is waiting: `systemOrange`.
    case waiting
    /// None is waiting and at least one is unreviewed:
    /// `controlAccentColor`.
    case unreviewed

    /// Orange when any session is waiting, else the accent color when any
    /// is unreviewed, else no dot (nil).
    public static func of(hasWaiting: Bool, hasUnreviewed: Bool) -> StateDot? {
        if hasWaiting { return .waiting }
        if hasUnreviewed { return .unreviewed }
        return nil
    }
}
