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
