// Desktop notification decision logic (DESIGN.md §4.5), factored out of
// UNUserNotificationCenter so it's independently testable:
//  1. Rising-edge detection for `unreviewed` (with already-fired bookkeeping
//     so the same edge is never notified twice, even across a snapshot +
//     later reconcile both reporting the same still-true state).
//  2. The delayed (3s) re-check decision (no foreground suppression, §8.16).
//  3. Notification content (title/subtitle/body) for a waiting or done edge.
//  4. The banner/sound delivery decision for the two independent mute
//     switches (Mute Banners / Mute Sound, §4.5/§8.14 2026-07-05 addendum).
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

/// Delivery decision for the two independent mute switches (DESIGN.md §4.5,
/// §8.14 2026-07-05 addendum: "Mute Banners" and "Mute Sound" are orthogonal,
/// so all four combinations are valid). Computed at the same delayed (3s)
/// re-check moment as `DelayedNotificationDecision`, so a toggle flipped
/// during the delay is respected.
public struct NotificationDeliveryDecision: Equatable, Sendable {
    /// Whether to deliver a `UNNotificationRequest` banner at all.
    public let deliverBanner: Bool
    /// If `deliverBanner`, whether to attach `UNNotificationSound` to it.
    public let attachBannerSound: Bool
    /// Mute Banners only ("sound-only mode", §4.5): no banner is delivered,
    /// but the app plays the system alert sound directly instead of relying
    /// on `UNNotificationSound`. This path intentionally does NOT follow
    /// Focus/Do Not Disturb (§4.5) — only a banner's attached sound does.
    public let playStandaloneSound: Bool

    public init(deliverBanner: Bool, attachBannerSound: Bool, playStandaloneSound: Bool) {
        self.deliverBanner = deliverBanner
        self.attachBannerSound = attachBannerSound
        self.playStandaloneSound = playStandaloneSound
    }
}

/// Decides banner/sound delivery from the two independent mute switches
/// (DESIGN.md §4.5):
///  - neither muted: banner + attached sound (current behavior).
///  - Mute Sound only: banner, no sound.
///  - Mute Banners only: no banner, standalone (app-played) sound instead —
///    "sound-only mode".
///  - both muted: nothing.
public enum NotificationDeliveryPolicy {
    public static func decide(muteBanners: Bool, muteSound: Bool) -> NotificationDeliveryDecision {
        switch (muteBanners, muteSound) {
        case (false, false):
            return NotificationDeliveryDecision(
                deliverBanner: true, attachBannerSound: true, playStandaloneSound: false
            )
        case (false, true):
            return NotificationDeliveryDecision(
                deliverBanner: true, attachBannerSound: false, playStandaloneSound: false
            )
        case (true, false):
            return NotificationDeliveryDecision(
                deliverBanner: false, attachBannerSound: false, playStandaloneSound: true
            )
        case (true, true):
            return NotificationDeliveryDecision(
                deliverBanner: false, attachBannerSound: false, playStandaloneSound: false
            )
        }
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
