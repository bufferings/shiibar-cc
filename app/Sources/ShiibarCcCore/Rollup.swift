// Tray icon rollup (the tray section of menubar-design.html, DESIGN.md §4.5):
// one status glyph (and, while working, three dots) represents the whole
// agent table, plus one corner dot: orange while any agent is waiting,
// else the accent color while any agent is unreviewed (`StateDot`).

import Foundation

/// The rolled-up status glyph shown in the tray, in priority order
/// waiting > working > idle (menubar-design.html). `.none` means "no
/// agents" (or, per DESIGN.md §4.5, "daemon disconnected" — the tray must
/// not show a stale rollup while disconnected).
///
/// Every glyph is a static image: each change of the status item's image
/// costs AppKit a fixed re-snapshot on the main thread, so `.working`
/// carries no animation frame. `.idle` and `.none` both render the static
/// ✻ in the emblem slot (M24 T1); they differ only in
/// `TrayIconState.dim`.
public enum TrayGlyph: Equatable, Sendable {
    case waiting
    case working
    case idle
    case none
}

/// Full tray rendering state: glyph, dim level, and the corner dot (nil =
/// no dot).
public struct TrayIconState: Equatable, Sendable {
    public let glyph: TrayGlyph
    public let dim: Double
    public let dot: StateDot?

    public init(glyph: TrayGlyph, dim: Double, dot: StateDot?) {
        self.glyph = glyph
        self.dim = dim
        self.dot = dot
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
    ///   - statuses: every tracked agent's status (while disconnected, the
    ///     last list received).
    ///   - hasUnreviewed: whether at least one agent has `unreviewed == true`.
    ///   - daemonConnected: `false` while reconnecting (§4.5); forces the
    ///     "no agents" glyph and dim level regardless of `statuses`, since a
    ///     stale rollup must not be shown as current. The corner dot is
    ///     still decided from the last list received, and drawn dimmed with
    ///     the rest of the tray (§4.5 "visual source of truth").
    ///
    /// An `.unknown` status (forward-compat fallback) is ignored entirely
    /// (DESIGN.md §4.2/§4.5: clients ignore unknown statuses): it does not
    /// participate in the rollup, same as the list hides it. If every
    /// agent's status is unknown, the tray shows the no-agents glyph.
    public static func icon(
        statuses: [AgentStatus],
        hasUnreviewed: Bool,
        daemonConnected: Bool
    ) -> TrayIconState {
        let known = statuses.filter { $0 != .unknown }
        let dot = StateDot.of(hasWaiting: known.contains(.waiting), hasUnreviewed: hasUnreviewed)
        guard daemonConnected, !known.isEmpty else {
            return TrayIconState(glyph: .none, dim: noAgentsDim, dot: dot)
        }
        if known.contains(.waiting) {
            return TrayIconState(glyph: .waiting, dim: normalDim, dot: dot)
        }
        if known.contains(.working) {
            return TrayIconState(glyph: .working, dim: normalDim, dot: dot)
        }
        return TrayIconState(glyph: .idle, dim: idleDim, dot: dot)
    }
}
