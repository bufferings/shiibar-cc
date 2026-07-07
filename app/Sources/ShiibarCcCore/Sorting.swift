// Dropdown "Sort by" modes (DESIGN.md §4.5, the dropdown section of
// menubar-design.html): three ways to order the agent list. "Newest
// session" and "Recent activity" are flat lists ordered by a wire
// timestamp; "Grouped" is the existing status-grouped layout (`Grouping`,
// unchanged) and doesn't use `flatOrder` below.
//
// Freezing the order while the dropdown stays open (§4.5: "the order is
// settled at the moment it opens; rows don't move while it's open") is an
// app-layer concern — the same `dropdownOpenedAt`-snapshot pattern already
// used for elapsed times (`AppState`) — since it's about *when* this pure
// comparison gets called, not the comparison itself.

import Foundation

/// The three "Sort by" choices in the ⌄ menu (§4.5/§8.25), in the order
/// they're listed there (radio order is default-first). `grouped` is the
/// default (§8.25) — see `defaultMode` below for the single source of truth
/// `AppState` falls back to when no sort mode is stored yet.
public enum SortMode: String, CaseIterable, Sendable {
    case grouped
    case newestSession
    case recentActivity

    /// Menu label (English UI text, §4.5).
    public var menuTitle: String {
        switch self {
        case .grouped: return "Grouped"
        case .newestSession: return "Newest session"
        case .recentActivity: return "Recent activity"
        }
    }

    /// Fallback used when no sort mode is stored yet (§8.25, 2026-07-08:
    /// changed from `.newestSession`). `AppState.init` reads this instead of
    /// hardcoding a case literal so the default has one place to change and
    /// is covered by a `ShiibarCcCoreTests` test (AppState itself has no
    /// test target — it lives in `ShiibarCcApp`, not `ShiibarCcCore`).
    public static let defaultMode: SortMode = .grouped
}

public enum Sorting {
    /// Order `agents` for a flat sort mode, newest-first. Not meaningful for
    /// `.grouped` (that mode's order comes from `Grouping.groupedRows`
    /// instead, which also does its own per-group unreviewed-first sort —
    /// §4.5: flat modes deliberately do NOT move unreviewed rows to the
    /// top, to keep the order stable).
    ///
    /// `.unknown`-status agents are excluded, matching `Grouping`'s existing
    /// "clients ignore unknown statuses" treatment (§4.2/§4.5).
    ///
    /// Ties (equal timestamps) keep their relative order from `agents`
    /// (`Array.sorted` is a stable sort in Swift), so calling this twice
    /// with unchanged input never reorders equal-key rows against itself.
    public static func flatOrder(agents: [Agent], mode: SortMode) -> [Agent] {
        let known = agents.filter { $0.status != .unknown }
        switch mode {
        case .grouped:
            return known
        case .newestSession:
            return known.sorted { $0.createdAt > $1.createdAt }
        case .recentActivity:
            return known.sorted { $0.lastReportAt > $1.lastReportAt }
        }
    }
}
