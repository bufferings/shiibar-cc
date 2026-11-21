// The ⌄ menu's `Mark all as read` (DESIGN.md §4.5 "⌄ menu", §8.24): clears
// the unreviewed flag of every session by running `shiibar-cc seen <target>`
// once per unreviewed target. It clears the accent-color dots only; a
// waiting session's orange stays until it stops waiting (§3.1). Delivered
// Notification Center notifications are not touched (§8.24).

import Foundation

public enum MarkAllAsRead {
    /// The item is enabled only while at least one agent is unreviewed.
    public static func isEnabled(agents: [Agent]) -> Bool {
        agents.contains { $0.unreviewed }
    }

    /// The targets to run `seen` for: every unreviewed agent, in list order.
    public static func targets(agents: [Agent]) -> [String] {
        agents.filter(\.unreviewed).map(\.target)
    }
}
