// Tray icon rollup (menubar-design.html "トレイ" section, DESIGN.md §4.5):
// one status glyph represents the whole agent table, plus an independent
// red-dot flag for "any agent unreviewed".

import Foundation

/// The rolled-up status glyph shown in the tray, in priority order
/// waiting > working > idle (menubar-design.html). `.none` means "no
/// agents" (or, per DESIGN.md §4.5, "daemon disconnected" — the tray must
/// not show a stale rollup while disconnected).
public enum TrayGlyph: Equatable, Sendable {
    case waiting
    case working
    case idle
    case none
}

/// Full tray rendering state: glyph, dim level, and whether the red
/// unreviewed dot should be drawn.
public struct TrayIconState: Equatable, Sendable {
    public let glyph: TrayGlyph
    public let dim: Double
    public let hasUnreviewedDot: Bool

    public init(glyph: TrayGlyph, dim: Double, hasUnreviewedDot: Bool) {
        self.glyph = glyph
        self.dim = dim
        self.hasUnreviewedDot = hasUnreviewedDot
    }
}

public enum Rollup {
    /// Dim level for "all idle" (menubar-design.html: 2 dim stages).
    public static let idleDim: Double = 0.8
    /// Dim level for "no agents" — also used for "daemon disconnected"
    /// (DESIGN.md §4.5: "disconnected while dimming the tray the same as
    /// no-agents, so a stale rollup isn't mistaken for current").
    public static let noAgentsDim: Double = 0.45
    /// Normal (non-dimmed) opacity.
    public static let normalDim: Double = 1.0

    /// Compute the tray icon state from the current agent statuses.
    ///
    /// - Parameters:
    ///   - statuses: every tracked agent's status.
    ///   - hasUnreviewed: whether at least one agent has `unreviewed == true`.
    ///   - daemonConnected: `false` while reconnecting (§4.5); forces the
    ///     "no agents" dim level regardless of `statuses`, since a stale
    ///     rollup must not be shown as current.
    ///
    /// Note: an `.unknown` status (forward-compat, §4.2) does not fit the
    /// documented waiting/working/idle priority order. This implementation
    /// treats it as the lowest tier (same as idle) rather than elevating
    /// the rollup on an unrecognized status — DESIGN.md does not spell this
    /// case out explicitly (flagged as a spec ambiguity in the M4 report).
    public static func icon(statuses: [AgentStatus], hasUnreviewed: Bool, daemonConnected: Bool) -> TrayIconState {
        guard daemonConnected else {
            return TrayIconState(glyph: .none, dim: noAgentsDim, hasUnreviewedDot: hasUnreviewed)
        }
        guard !statuses.isEmpty else {
            return TrayIconState(glyph: .none, dim: noAgentsDim, hasUnreviewedDot: hasUnreviewed)
        }
        if statuses.contains(.waiting) {
            return TrayIconState(glyph: .waiting, dim: normalDim, hasUnreviewedDot: hasUnreviewed)
        }
        if statuses.contains(.working) {
            return TrayIconState(glyph: .working, dim: normalDim, hasUnreviewedDot: hasUnreviewed)
        }
        // Everything left is idle or unknown (lowest tier either way).
        return TrayIconState(glyph: .idle, dim: idleDim, hasUnreviewedDot: hasUnreviewed)
    }
}
