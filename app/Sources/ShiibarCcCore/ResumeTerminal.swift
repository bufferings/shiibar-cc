// Which terminal the Conversations Resume button opens in (DESIGN.md §4.6 /
// M40 T6). Resume makes no decision of its own (§4.4) — the app decides from
// observation and passes `--terminal`. The decision is pure and lives here so
// a test can pin it; the UserDefaults IO and the CLI call live in the app
// target.
//
// The rule (§4.6/§8.47 — observation, no setting, no first-run question):
//   1. the newest agent entry (max `last_seen`) whose target prefix names a
//      supported terminal,
//   2. else the last observed kind (remembered in UserDefaults, updated every
//      time entries are observed — so it survives the agent list emptying),
//   3. else `iterm2`.
// This is always right for someone who only uses one terminal, and follows a
// switch automatically.

import Foundation

public enum ResumeTerminal {
    /// `--terminal` value for iTerm2 (the target prefix without the `:`).
    public static let iterm2 = "iterm2"
    /// `--terminal` value for Terminal.app.
    public static let appleTerminal = "apple-terminal"

    /// UserDefaults key holding the last observed terminal kind (rule 2).
    public static let userDefaultsKey = "cc.shiibar.lastObservedTerminal"

    /// The supported-terminal `--terminal` value a target's prefix names, or
    /// `nil` if the prefix isn't one this app knows (§2/§4.3). A `:`-less or
    /// unknown-prefix target is unrecognized.
    public static func kind(ofTarget target: String) -> String? {
        if target.hasPrefix("\(iterm2):") {
            return iterm2
        }
        if target.hasPrefix("\(appleTerminal):") {
            return appleTerminal
        }
        return nil
    }

    /// The newest agent entry's terminal kind (rule 1): scan by descending
    /// `last_seen` and take the first entry whose prefix is recognized.
    /// `nil` when there are no such entries. Ties in `last_seen` are broken
    /// arbitrarily but deterministically (stable order), which is immaterial
    /// — the caller only needs *a* current terminal.
    public static func newestObservedKind(agents: [Agent]) -> String? {
        agents
            .sorted { $0.lastSeen > $1.lastSeen }
            .lazy
            .compactMap { kind(ofTarget: $0.target) }
            .first
    }

    /// Decide the `--terminal` value (§4.6/T6): newest observed entry's kind,
    /// else the remembered kind, else `iterm2`.
    public static func decide(agents: [Agent], remembered: String?) -> String {
        newestObservedKind(agents: agents) ?? remembered ?? iterm2
    }
}
