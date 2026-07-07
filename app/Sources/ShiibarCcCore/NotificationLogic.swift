// Desktop notification decision logic (DESIGN.md §4.5), factored out of
// UNUserNotificationCenter so it's independently testable:
//  1. Rising-edge detection for `unreviewed` (with already-fired bookkeeping
//     so the same edge is never notified twice, even across a snapshot +
//     later reconcile both reporting the same still-true state).
//  2. The delayed (3s) re-check decision (no foreground suppression, §8.16).
//  3. Notification content (title/subtitle/body) for a waiting or done edge.
//  4. The sound attached to the banner (§4.5/§8.26/§8.27): the banner is
//     always delivered — Mute Banners was removed (§8.27), so there is only
//     one mute switch (Mute Sound) left, and one choice left to make (which
//     of the Waiting/Done sounds to attach, or none if muted).
//  5. Which notification-cleanup path is allowed to sweep delivered
//     notifications for a removed target.

import Foundation

/// One rising edge of `unreviewed` (false -> true) detected by
/// `UnreviewedEdgeTracker.observe`. Both `waiting` and `idle` (completion)
/// edges get a toast + the standard sound (§4.5/§8.16) — `status` only
/// changes the title/interruption level, not whether a sound plays.
public struct UnreviewedEdge: Equatable, Sendable {
    public let target: String
    public let status: AgentStatus

    public init(target: String, status: AgentStatus) {
        self.target = target
        self.status = status
    }
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
    ///
    /// `baseline: true` (DESIGN.md §4.5 addendum: "the first snapshot after
    /// app launch is a baseline") records the current unreviewed set without
    /// reporting any edges for it — used exactly once, for the very first
    /// snapshot an app process receives, so pre-existing unreviewed entries
    /// at launch don't re-notify (the red badge already shows the backlog).
    /// Every later observation (reconnect snapshots included, and any
    /// `status_changed` / reconcile update) must pass `baseline: false` so
    /// rising edges are reported as usual.
    @discardableResult
    public func observe(agents: [Agent], baseline: Bool = false) -> [UnreviewedEdge] {
        var edges: [UnreviewedEdge] = []
        var next: Set<String> = []
        for agent in agents where agent.unreviewed {
            next.insert(agent.target)
            if !baseline && !currentlyUnreviewed.contains(agent.target) {
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

/// The delayed (3s) re-check decision (DESIGN.md §4.5/§8.16): at timer-fire
/// time, re-fetch the latest state and only notify if the target is *still*
/// unreviewed. Foreground suppression was removed in M5 (§8.16) — a target
/// being frontmost no longer withholds the notification.
public enum DelayedNotificationDecision {
    public static func shouldNotify(currentlyUnreviewed: Bool) -> Bool {
        currentlyUnreviewed
    }
}

/// A notification's rendered content (DESIGN.md §4.5): title always present,
/// subtitle/body omitted entirely when the underlying field isn't there
/// (the hook never carried it) rather than shown empty.
public struct NotificationContent: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    public let body: String?
}

/// Builds notification content for a rising `unreviewed` edge (§4.5):
///  - waiting: title "Waiting for you — <label>", subtitle = `message`
///    (the waiting reason, e.g. "Claude needs your permission"), body =
///    `task` (what was last asked).
///  - done (any non-waiting edge status, i.e. `idle`): title
///    "Done — <label>", body = `lastAssistantMessage` if present, else
///    `task`. No subtitle.
/// `label` is the same cwd label the dropdown's second line uses (§3.6),
/// passed in rather than computed here since that formatting rule
/// (`CwdLabel`) needs `$HOME` the caller already has.
public enum NotificationContentBuilder {
    public static func build(
        status: AgentStatus,
        label: String,
        message: String?,
        task: String?,
        lastAssistantMessage: String?
    ) -> NotificationContent {
        if status == .waiting {
            return NotificationContent(
                title: "Waiting for you — \(label)",
                subtitle: message,
                body: task
            )
        }
        return NotificationContent(
            title: "Done — \(label)",
            subtitle: nil,
            body: lastAssistantMessage ?? task
        )
    }
}

/// The sound name attached to a notification banner (DESIGN.md §4.5/§8.26/
/// §8.27): the banner itself is always delivered now that Mute Banners is
/// gone (§8.27) — this only decides whether a sound accompanies it (`nil`
/// when Mute Sound is on, per §4.5: when Mute sound is ON, content.sound =
/// nil), and which of the Settings window's per-event choices to use
/// (Waiting vs Done, §8.26). Computed at the same delayed (3s) re-check
/// moment as `DelayedNotificationDecision`, so a Settings change made during
/// the delay is respected.
public enum NotificationSoundPolicy {
    public static func soundName(
        status: AgentStatus,
        waitingSoundName: String,
        doneSoundName: String,
        muted: Bool
    ) -> String? {
        guard !muted else { return nil }
        return status == .waiting ? waitingSoundName : doneSoundName
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
