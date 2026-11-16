// Which verb the Conversations bottom panel offers for the selected
// conversation (DESIGN.md §4.6 / §8.48 / M41 T1). The bottom panel is a
// single verb with two faces: past conversations get Resume (reopen in a new
// window), running ones get Jump (go to the terminal tab that's driving it).
// The decision is pure and lives here so a test can pin it; the CLI call, the
// focus/exit-code IO, and the SwiftUI rendering live in the app target — the
// same split as `ResumeTerminal`.
//
// The four outcomes (§4.6/§8.48):
//   - past + cwd present  -> Resume, enabled
//   - past + no cwd        -> Resume, disabled (resume needs an absolute cwd, §4.4)
//   - live + a session_id match in the agent list -> Jump, enabled (carries
//     the matched entry's target)
//   - live + no match      -> Jump, disabled (running in a terminal this app
//     can't drive — §8.11 / §8.48)

import Foundation

public enum ConversationAction: Equatable {
    /// Past conversation with a known cwd: reopen it in a new terminal window.
    case resume
    /// Past conversation without a cwd: Resume is shown disabled — resume
    /// needs an absolute cwd (§4.4). Preserves the existing `canResume`
    /// behavior (M41 T1).
    case resumeDisabled
    /// Running conversation matched to an agent entry: jump (focus) to
    /// `target`, the terminal tab driving it.
    case jump(target: String)
    /// Running conversation with no matching agent entry: Jump is shown
    /// disabled — it's running in a terminal this app can't drive (§8.48).
    case jumpDisabled

    /// Derive the panel verb for `summary` against the agent list `agents` as
    /// it stands at this moment (§4.6/§8.48). Matching is exact `session_id`
    /// equality; a duplicate match (not expected — session_id is unique) takes
    /// the first entry (no invented defense — §8.48/M41 T1).
    public static func derive(for summary: ConversationSummary, agents: [Agent]) -> ConversationAction {
        guard summary.live else {
            // Past: Resume, enabled only when the cwd is known.
            return (summary.cwd?.isEmpty == false) ? .resume : .resumeDisabled
        }
        if let match = agents.first(where: { $0.sessionId == summary.sessionID }) {
            return .jump(target: match.target)
        }
        return .jumpDisabled
    }
}

// MARK: - Running rows and Branch (M44, DESIGN.md §4.5 "action buttons", §4.6
// "bottom panel", §8.49)

extension ConversationAction {
    /// The bottom panel's primary button for a selected Running row
    /// (§4.6): always Jump to the row's target — the daemon
    /// tracks it, so there is no disabled case and no pre-check (§4.6
    /// "Jump").
    public static func derive(forRunningAgent agent: Agent) -> ConversationAction {
        .jump(target: agent.target)
    }

    /// The view-facing button for this verb. `sessionID` / `cwd` feed the
    /// Resume invocation. The disabled Resume keeps the `Resume` tooltip
    /// (§4.6); the disabled Jump carries the untracked-terminal tooltip.
    public func button(sessionID: String, cwd: String?) -> RowButton {
        switch self {
        case .resume:
            // `.resume` is only derived with a non-empty cwd; stay defensive.
            guard let cwd, !cwd.isEmpty else {
                return RowButton(kind: .resume, invocation: nil, tooltip: RowButtonKind.resume.title)
            }
            return RowButton(
                kind: .resume,
                invocation: .resume(sessionID: sessionID, cwd: cwd),
                tooltip: RowButtonKind.resume.title
            )
        case .resumeDisabled:
            return RowButton(kind: .resume, invocation: nil, tooltip: RowButtonKind.resume.title)
        case .jump(let target):
            return RowButton(kind: .jump, invocation: .jump(target: target), tooltip: RowButtonKind.jump.title)
        case .jumpDisabled:
            return RowButton(kind: .jump, invocation: nil, tooltip: RowButton.untrackedRunningTooltip)
        }
    }

    /// The Branch button (§4.5/§4.6): enabled when both the session_id and
    /// the cwd are known (Running rows: either empty disables it; History
    /// rows: no cwd disables it). Branch works on running conversations too
    /// (§7-6). The tooltip stays `Branch` while disabled (§4.6).
    public static func branchButton(sessionID: String, cwd: String?) -> RowButton {
        guard !sessionID.isEmpty, let cwd, !cwd.isEmpty else {
            return RowButton(kind: .branch, invocation: nil, tooltip: RowButtonKind.branch.title)
        }
        return RowButton(
            kind: .branch,
            invocation: .branch(sessionID: sessionID, cwd: cwd),
            tooltip: RowButtonKind.branch.title
        )
    }
}

// MARK: - CLI arguments of a row verb (DESIGN.md §4.5 "Jump", §4.6 "Resume
// and Branch")

extension RowInvocation {
    /// The `shiibar-cc` arguments for this verb. `terminal` is the
    /// `--terminal` value decided by `ResumeTerminal.decide` (§4.6); Jump
    /// ignores it.
    ///   - Jump:   `focus <target>`
    ///   - Resume: `resume --cwd <cwd> --terminal <t> <session_id>`
    ///   - Branch: `resume --cwd <cwd> --terminal <t> --fork <session_id>`
    public func cliArguments(terminal: String) -> [String] {
        switch self {
        case .jump(let target):
            return ["focus", target]
        case .resume(let sessionID, let cwd):
            return ["resume", "--cwd", cwd, "--terminal", terminal, sessionID]
        case .branch(let sessionID, let cwd):
            return ["resume", "--cwd", cwd, "--terminal", terminal, "--fork", sessionID]
        }
    }
}
