// The conversation pane reload (DESIGN.md §4.6 "conversation pane reload",
// §8.65): the pure decisions behind it. Which agent-table update is a
// status-change trigger, and how a newly fetched message list relates to
// the one on screen. The model (`MainSurfaceModel`) runs the subprocesses
// and applies the surface-visibility condition; the page draws what Swift
// decided (§4.6 "rendering engine": the page never decides semantics).

import Foundation

public enum ConversationPaneReload {
    /// §9: after a status-change reload completes, the pane reloads once
    /// more after this delay (content the transcript received after the
    /// status notification).
    public static let followUpSeconds: Double = 2

    /// The pane's index run: catch-up only, no progress stream (its output
    /// is not shown — §4.6).
    public static let indexArguments = ["conversations", "index"]

    /// Trigger 1 (§4.6): the session_id to reload when the agent-table
    /// update from `before` to `after` changed the `status` of the Running
    /// row whose conversation the pane shows; nil otherwise. Only a change
    /// between working / waiting / idle counts: a change of `unreviewed`
    /// alone, of any other field alone, and a row appearing or disappearing
    /// are not triggers. The pane must show the same Running row (same
    /// target and session_id) before and after, with a non-empty
    /// session_id. Whether a surface is on screen is not decided here.
    public static func statusChangeTrigger(before: UnifiedListState, after: UnifiedListState) -> String? {
        guard before.isConversationPaneVisible, after.isConversationPaneVisible,
              let shown = after.selection, shown == before.selection,
              case .running(let target) = shown.key, !shown.sessionID.isEmpty,
              let old = before.agents.first(where: { $0.target == target }),
              let new = after.agents.first(where: { $0.target == target }),
              old.sessionId == shown.sessionID, new.sessionId == shown.sessionID,
              countsAsStatus(old.status), countsAsStatus(new.status),
              old.status != new.status
        else { return nil }
        return shown.sessionID
    }

    private static func countsAsStatus(_ status: AgentStatus) -> Bool {
        status == .working || status == .waiting || status == .idle
    }
}

/// How a reloaded message list relates to the displayed one (§4.6
/// "applying the result"). Two messages are the same message when `seq`,
/// `role`, and `text` all match.
public enum ConversationPaneUpdate: Equatable, Sendable {
    /// The same messages in the same order: only the end marker's elapsed
    /// time changes.
    case unchanged
    /// Every displayed message is unchanged and messages were added at the
    /// end, starting at this index of the fetched list.
    case appended(firstNewIndex: Int)
    /// A displayed message changed or went away: the page renders the whole
    /// list again. `keptIndices` maps a displayed message's index to the
    /// index of the same message in the fetched list (the page keeps the
    /// message at the top of the viewport in place when it is still there).
    case replaced(keptIndices: [Int: Int])

    public static func classify(
        displayed: [ConversationMessage], fetched: [ConversationMessage]
    ) -> ConversationPaneUpdate {
        if fetched.count >= displayed.count, Array(fetched.prefix(displayed.count)) == displayed {
            return fetched.count == displayed.count ? .unchanged : .appended(firstNewIndex: displayed.count)
        }
        var fetchedIndexBySeq: [Int64: Int] = [:]
        for (index, message) in fetched.enumerated() where fetchedIndexBySeq[message.seq] == nil {
            fetchedIndexBySeq[message.seq] = index
        }
        var kept: [Int: Int] = [:]
        for (index, message) in displayed.enumerated() {
            if let match = fetchedIndexBySeq[message.seq], fetched[match] == message {
                kept[index] = match
            }
        }
        return .replaced(keptIndices: kept)
    }
}
