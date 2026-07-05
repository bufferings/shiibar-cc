// Dropdown grouping/sorting (DESIGN.md §4.5, the dropdown section of
// menubar-design.html): group by status (Waiting / Working / Idle, empty
// groups hidden), unreviewed rows first within each group, row content
// derived from `message` (waiting) / `task` / label promotion.

import Foundation

/// One dropdown row's derived display content — everything the SwiftUI view
/// needs, precomputed so the view itself has no business logic.
public struct AgentRow: Equatable, Identifiable, Sendable {
    public var id: String { target }
    public let target: String
    public let status: AgentStatus
    public let unreviewed: Bool
    /// Line 1 (menubar-design.html): `message` for waiting, `task`
    /// otherwise, promoted to the label if neither is present (§3.6).
    public let primaryLine: String
    /// Line 2 left half: the cwd label (§4.5).
    public let label: String
    public let elapsedSeconds: Int64

    public init(
        target: String,
        status: AgentStatus,
        unreviewed: Bool,
        primaryLine: String,
        label: String,
        elapsedSeconds: Int64
    ) {
        self.target = target
        self.status = status
        self.unreviewed = unreviewed
        self.primaryLine = primaryLine
        self.label = label
        self.elapsedSeconds = elapsedSeconds
    }
}

/// A non-empty group of rows for one status heading.
public struct AgentGroup: Equatable, Identifiable, Sendable {
    public var id: AgentStatus { status }
    public let status: AgentStatus
    public let rows: [AgentRow]
}

public enum Grouping {
    /// Group display order (menubar-design.html: Waiting -> Working -> Idle).
    public static let groupOrder: [AgentStatus] = [.waiting, .working, .idle]

    /// Build one row's derived display content from a raw `Agent` (§3.6/§4.5).
    public static func makeRow(agent: Agent, now: Int64, home: String?) -> AgentRow {
        let label = CwdLabel.format(cwd: agent.cwd, home: home)
        let primary: String
        if agent.status == .waiting {
            primary = agent.message ?? agent.task ?? label
        } else {
            primary = agent.task ?? label
        }
        return AgentRow(
            target: agent.target,
            status: agent.status,
            unreviewed: agent.unreviewed,
            primaryLine: primary,
            label: label,
            elapsedSeconds: max(0, now - agent.since)
        )
    }

    /// Group and sort the whole agent table for the dropdown. Empty groups
    /// (including for statuses this build doesn't lay out, e.g. `.unknown`)
    /// are omitted entirely (menubar-design.html: "empty groups hidden").
    /// Within a group, unreviewed rows sort first; ties keep relative order
    /// (`Array.sorted` is a stable sort in Swift, so re-opening the dropdown
    /// without any change keeps a stable layout, matching the spec's
    /// stable-ordering requirement — §4.5: the order must be stable every
    /// time the dropdown opens).
    public static func groupedRows(agents: [Agent], now: Int64, home: String?) -> [AgentGroup] {
        var groups: [AgentGroup] = []
        for status in groupOrder {
            let rows = agents
                .filter { $0.status == status }
                .map { makeRow(agent: $0, now: now, home: home) }
                .sorted { lhs, rhs in lhs.unreviewed && !rhs.unreviewed }
            if !rows.isEmpty {
                groups.append(AgentGroup(status: status, rows: rows))
            }
        }
        return groups
    }
}
