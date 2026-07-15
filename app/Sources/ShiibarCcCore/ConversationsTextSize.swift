// Text-size rules for the Conversations window's right pane (DESIGN.md
// §4.6/§9): cmd-plus / cmd-minus / cmd-0 (and the Settings window's
// Conversations popup) move the body size within 10-20pt, default 13pt;
// code blocks track the body at -1.5pt. The list and the status line are
// unaffected. Persistence (UserDefaults) and the key handling live in
// ShiibarCcApp; the numbers and the clamping are pinned here by tests.

import Foundation

public enum ConversationsTextSize {
    /// §9: smallest body size (points).
    public static let minimum: Double = 10
    /// §9: largest body size (points).
    public static let maximum: Double = 20
    /// §9: default body size (points), also the cmd-0 reset target.
    public static let defaultSize: Double = 13
    /// One cmd-plus / cmd-minus step and the popup's increment (points).
    public static let step: Double = 1
    /// §9: code blocks render at body size + this delta.
    public static let codeDelta: Double = -1.5

    /// Clamp any candidate size into the §9 range.
    public static func clamp(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    /// The size after one cmd-plus step (clamped).
    public static func increased(_ value: Double) -> Double {
        clamp(value + step)
    }

    /// The size after one cmd-minus step (clamped).
    public static func decreased(_ value: Double) -> Double {
        clamp(value - step)
    }
}
