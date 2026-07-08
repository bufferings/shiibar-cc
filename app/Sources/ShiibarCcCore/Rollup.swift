// Tray icon rollup (the tray section of menubar-design.html, DESIGN.md §4.5):
// one status glyph represents the whole agent table, plus an independent
// red-dot flag for "any agent unreviewed".

import Foundation

/// The rolled-up status glyph shown in the tray, in priority order
/// waiting > working > idle (menubar-design.html). `.none` means "no
/// agents" (or, per DESIGN.md §4.5, "daemon disconnected" — the tray must
/// not show a stale rollup while disconnected).
///
/// `.working` carries the current `GlyphCycleSpinner` frame index (M24 T1:
/// the tray emblem slot runs the same glyph-cycle spinner as the dropdown
/// row symbol, §9) — the glyph alone doesn't say which cycle frame is
/// current, so the frame index travels with it. `.idle` and `.none` both
/// render the static ✻ in the emblem slot (M24 T1); they differ only in
/// `TrayIconState.dim`.
public enum TrayGlyph: Equatable, Sendable {
    case waiting
    case working(frame: Int)
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
    ///   - workingFrame: the current `GlyphCycleSpinner` frame index
    ///     (0..<`GlyphCycleSpinner.glyphs.count`) to stamp onto a `.working`
    ///     result; irrelevant otherwise. Defaults to 0 for callers that
    ///     don't animate (e.g. tests).
    ///
    /// An `.unknown` status (forward-compat fallback) is ignored entirely
    /// (DESIGN.md §4.2/§4.5: clients ignore unknown statuses): it does not
    /// participate in the rollup, same as the dropdown hides it. If every
    /// agent's status is unknown, the tray shows the no-agents glyph.
    public static func icon(
        statuses: [AgentStatus],
        hasUnreviewed: Bool,
        daemonConnected: Bool,
        workingFrame: Int = 0
    ) -> TrayIconState {
        guard daemonConnected else {
            return TrayIconState(glyph: .none, dim: noAgentsDim, hasUnreviewedDot: hasUnreviewed)
        }
        let known = statuses.filter { $0 != .unknown }
        guard !known.isEmpty else {
            return TrayIconState(glyph: .none, dim: noAgentsDim, hasUnreviewedDot: hasUnreviewed)
        }
        if known.contains(.waiting) {
            return TrayIconState(glyph: .waiting, dim: normalDim, hasUnreviewedDot: hasUnreviewed)
        }
        if known.contains(.working) {
            return TrayIconState(glyph: .working(frame: workingFrame), dim: normalDim, hasUnreviewedDot: hasUnreviewed)
        }
        return TrayIconState(glyph: .idle, dim: idleDim, hasUnreviewedDot: hasUnreviewed)
    }
}
