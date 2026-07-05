// Desktop notifications (DESIGN.md §4.5/§8.16): UNUserNotificationCenter,
// fired on the unreviewed rising edge, delayed 3s with an unreviewed-only
// re-check (no foreground suppression — dropped in M5, §8.16), the standard
// sound for both waiting (time-sensitive) and done (active), threadIdentifier
// grouping per target, a mute toggle (UserDefaults, sound only), and cleanup
// that skips `session_end` removals. Rising-edge detection / de-dup / the
// delayed decision / content building / the cleanup rule are pure logic in
// ShiibarCcCore (`UnreviewedEdgeTracker`, `DelayedNotificationDecision`,
// `NotificationContentBuilder`, `NotificationCleanupRule`) — this type is the
// I/O wrapper around them.

import Foundation
import UserNotifications
import ShiibarCcCore

/// Delay before the re-check-and-maybe-fire (§4.5/§9: 3 seconds).
private let delaySeconds: TimeInterval = 3

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private let edgeTracker = UnreviewedEdgeTracker()
    /// Called (main actor) when a notification is clicked, to focus that target.
    var onFocusRequested: ((String) -> Void)?
    /// Reflects the current authorization status for the "denied" warning row (§4.5).
    @Published private(set) var permissionDenied = false

    private static let muteKey = "cc.shiibar.muteSound"
    var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.muteKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.muteKey) }
    }

    /// `UNUserNotificationCenter.current()` aborts the process
    /// (`bundleProxyForCurrentProcess is nil`) unless the running binary is
    /// inside a real `.app` bundle with a bundle identifier — which a
    /// `swift run` dev build (pre-`.app`, task brief M4 §1) never is. Only
    /// touch it lazily, and only once there's a real bundle identifier, so
    /// the dev workflow (attach to a manually-started daemon, no
    /// notifications) doesn't crash on launch.
    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    override init() {
        super.init()
    }

    func requestAuthorizationIfNeeded() {
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshPermissionStatus()
            }
        }
    }

    func refreshPermissionStatus() {
        center?.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.permissionDenied = settings.authorizationStatus == .denied
            }
        }
    }

    /// Feed the latest known agents (from any source: snapshot,
    /// status_changed, or a post-reconcile refresh, §4.5) to detect rising
    /// edges and schedule their delayed notifications.
    func observe(agents: [Agent]) {
        for edge in edgeTracker.observe(agents: agents) {
            scheduleDelayedNotification(for: edge)
        }
    }

    /// A target dropped out of the tracked set entirely (removed) — forget
    /// it so a future re-registration under the same target is a fresh edge.
    func forget(target: String) {
        edgeTracker.forget(target: target)
    }

    private func scheduleDelayedNotification(for edge: UnreviewedEdge) {
        let target = edge.target
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self else { return }
            // Re-check at fire time (§4.5): only the "still unreviewed?"
            // condition gates delivery now — foreground suppression was
            // dropped in M5 (§8.16), so there's no subprocess probe here
            // anymore, just a synchronous read of the live agent table.
            let agents = self.currentAgentsProvider()
            guard DelayedNotificationDecision.shouldNotify(
                currentlyUnreviewed: agents.contains(where: { $0.target == target && $0.unreviewed })
            ) else { return }
            guard let agent = agents.first(where: { $0.target == target }) else { return }
            self.deliver(edge: edge, agent: agent)
        }
    }

    /// Supplied by `AppState` so the delayed re-check and notification
    /// content both see live data rather than a stale capture from
    /// scheduling time.
    var currentAgentsProvider: () -> [Agent] = { [] }

    /// `$HOME`, used to render the same cwd label the dropdown's second line
    /// uses (§4.5/§3.6).
    var homeProvider: () -> String? = { nil }

    private func deliver(edge: UnreviewedEdge, agent: Agent) {
        let label = CwdLabel.format(cwd: agent.cwd, home: homeProvider())
        let built = NotificationContentBuilder.build(
            status: edge.status,
            label: label,
            message: agent.message,
            task: agent.task,
            lastAssistantMessage: agent.lastAssistantMessage
        )
        let content = UNMutableNotificationContent()
        content.title = built.title
        if let subtitle = built.subtitle {
            content.subtitle = subtitle
        }
        if let body = built.body {
            content.body = body
        }
        content.threadIdentifier = edge.target
        if #available(macOS 12.0, *) {
            content.interruptionLevel = edge.status == .waiting ? .timeSensitive : .active
        }
        // Both waiting and done play the same standard sound (§4.5/§8.16);
        // Mute Sound silences either.
        if !isMuted {
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: "\(edge.target)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center?.add(request)
    }

    /// Sweep delivered notifications for `target`, unless the reason forbids
    /// it (§4.2/§4.5: `session_end` must not wipe an unread completion toast).
    func sweepDelivered(target: String, reason: RemovalReason) {
        guard NotificationCleanupRule.shouldSweep(onRemovalReason: reason) else { return }
        sweepDelivered(target: target)
    }

    /// Sweep on focus / unreviewed-lowered (no removal reason involved).
    func sweepDelivered(target: String) {
        center?.getDeliveredNotifications { [weak self] notifications in
            let ids = notifications
                .filter { $0.request.content.threadIdentifier == target }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            self?.center?.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let target = response.notification.request.content.threadIdentifier
        Task { @MainActor in
            self.onFocusRequested?(target)
            completionHandler()
        }
    }
}
