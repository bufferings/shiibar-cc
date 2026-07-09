// "Sort by" modes (DESIGN.md §4.5/§8.31, the dropdown section of
// menubar-design.html): two ways to show the agent list, both keyed by
// `created_at` (immutable), so the order is stable by construction —
// "newest session first; Grouped is that order partitioned by status".
// Both modes are computed live on every render; no order-freezing
// machinery exists (§8.31 records the removal of the third mode — keyed
// on the ever-moving `last_report_at` — that needed it).

import Foundation

/// The two "Sort by" choices in the ⌄ / app menu (§4.5/§8.25/§8.31), in
/// the order they're listed there (radio order is default-first).
/// `grouped` is the default (§8.25) — see `defaultMode` below for the
/// single source of truth `AppState` falls back to when nothing (or an
/// unknown value) is stored.
public enum SortMode: String, CaseIterable, Sendable {
    case grouped
    case newestSession

    /// Menu label (English UI text, §4.5).
    public var menuTitle: String {
        switch self {
        case .grouped: return "Grouped"
        case .newestSession: return "Newest session"
        }
    }

    /// Fallback used when no sort mode is stored yet or the stored string
    /// is unknown — including the raw value persisted by builds that still
    /// had the third mode §8.31 removed (§8.25, 2026-07-08: changed from
    /// `.newestSession`). `AppState.init` reads this instead of hardcoding
    /// a case literal so the default has one place to change and is
    /// covered by a `ShiibarCcCoreTests` test (AppState itself has no test
    /// target — it lives in `ShiibarCcApp`, not `ShiibarCcCore`).
    public static let defaultMode: SortMode = .grouped
}

public enum Sorting {
    /// The flat "Newest session" order (§4.5/§8.31): `created_at`
    /// descending, computed live from the current agent table on every
    /// render — the same per-render approach as `Grouping.groupedRows`.
    ///
    /// `.unknown`-status agents are excluded, matching `Grouping`'s
    /// existing "clients ignore unknown statuses" treatment (§4.2/§4.5).
    ///
    /// Ties (equal timestamps) keep their relative order from `agents`
    /// (`Array.sorted` is a stable sort in Swift), so re-rendering with
    /// unchanged input never reorders equal-key rows against itself.
    public static func newestFirst(agents: [Agent]) -> [Agent] {
        agents
            .filter { $0.status != .unknown }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
