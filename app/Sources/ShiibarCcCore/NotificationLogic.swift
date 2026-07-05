// Desktop notification decision logic (DESIGN.md §4.5), factored out of
// UNUserNotificationCenter so it's independently testable:
//  1. Rising-edge detection for `unreviewed` (with already-fired bookkeeping
//     so the same edge is never notified twice, even across a snapshot +
//     later reconcile both reporting the same still-true state).
//  2. The delayed (3s) re-check decision.
//  3. Which notification-cleanup path is allowed to sweep delivered
//     notifications for a removed target.

import Foundation

/// One rising edge of `unreviewed` (false -> true) detected by
/// `UnreviewedEdgeTracker.observe`.
public struct UnreviewedEdge: Equatable, Sendable {
    public let target: String
    /// waiting = toast + sound (time-sensitive); idle (completion) = toast
    /// only (§4.5).
    public let status: AgentStatus

    public init(target: String, status: AgentStatus) {
        self.target = target
        self.status = status
    }

    /// Whether this edge's eventual notification should play a sound.
    public var playsSound: Bool { status == .waiting }
}

/// Tracks which targets are currently unreviewed, across any source
/// (snapshot / status_changed / reconcile, §4.5: "including ones noticed via
/// reconnect snapshot or reconcile"), to detect the false->true edge exactly
/// once per continuous unreviewed streak. This *is* the "already fired"
/// record DESIGN.md §4.5 requires — a target that's still unreviewed the
/// next time `observe` runs is not reported again, so callers never have to
/// de-dupe on their own.
public final class UnreviewedEdgeTracker {
    private var currentlyUnreviewed: Set<String> = []

    public init() {}

    /// Feed the latest known set of agents (however it was learned) and get
    /// back every target that just transitioned into unreviewed this call.
    @discardableResult
    public func observe(agents: [Agent]) -> [UnreviewedEdge] {
        var edges: [UnreviewedEdge] = []
        var next: Set<String> = []
        for agent in agents where agent.unreviewed {
            next.insert(agent.target)
            if !currentlyUnreviewed.contains(agent.target) {
                edges.append(UnreviewedEdge(target: agent.target, status: agent.status))
            }
        }
        currentlyUnreviewed = next
        return edges
    }

    /// Explicitly forget a target (e.g. it was removed) so a later
    /// re-registration under the same target is treated as a fresh edge.
    public func forget(target: String) {
        currentlyUnreviewed.remove(target)
    }

    /// Current bookkeeping, exposed only for tests.
    public var trackedTargets: Set<String> { currentlyUnreviewed }
}

/// The delayed (3s) re-check decision (DESIGN.md §4.5): at timer-fire time,
/// re-fetch the latest state and only notify if the target is *still*
/// unreviewed and not currently in the foreground (foreground suppression is
/// resolved by the caller via `shiibar-cc focused`, which is I/O and so
/// lives outside this pure function).
public enum DelayedNotificationDecision {
    public static func shouldNotify(currentlyUnreviewed: Bool, targetIsForeground: Bool) -> Bool {
        currentlyUnreviewed && !targetIsForeground
    }
}

/// Notification cleanup rule (DESIGN.md §4.5, §4.2): delivered notifications
/// for a target are swept on focus / unreviewed-lowered / agent_removed,
/// *except* when the removal reason is `sessionEnd` (closing the pane must
/// not wipe an unread completion toast).
public enum NotificationCleanupRule {
    public static func shouldSweep(onRemovalReason reason: RemovalReason) -> Bool {
        reason != .sessionEnd
    }
}
