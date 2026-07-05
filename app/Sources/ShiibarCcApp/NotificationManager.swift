// Desktop notifications (DESIGN.md §4.5/§8.16): UNUserNotificationCenter,
// fired on the unreviewed rising edge, delayed 3s with an unreviewed-only
// re-check (no foreground suppression — dropped in M5, §8.16), the standard
// sound for both waiting (time-sensitive) and done (active), threadIdentifier
// grouping per target, two independent mute toggles (UserDefaults: Mute
// Banners / Mute Sound, §4.5/§8.14 2026-07-05 addendum), and cleanup that
// skips `session_end` removals. The first `.snapshot` this process receives
// is a baseline: pre-existing unreviewed entries in it don't notify (§4.5
// 2026-07-05 addendum) — see `observeSnapshot`. Rising-edge detection /
// de-dup / baseline seeding / the delayed decision / content building / the
// mute delivery decision / the cleanup rule are pure logic in ShiibarCcCore
// (`UnreviewedEdgeTracker`, `DelayedNotificationDecision`,
// `NotificationContentBuilder`, `NotificationDeliveryPolicy`,
// `NotificationCleanupRule`) — this type is the I/O wrapper around them.

import AppKit
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

    /// "Mute Banners" (§4.5/§8.14 2026-07-05 addendum): independent from
    /// `isMuted` ("Mute Sound") — all four combinations are valid, see
    /// `NotificationDeliveryPolicy`.
    private static let muteBannersKey = "cc.shiibar.muteBanners"
    var isBannersMuted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.muteBannersKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.muteBannersKey) }
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

    /// Current notification authorization, reduced to `NotificationPermissionState`
    /// for the Setup Check window's row (§4.5, M5 T5). `getNotificationSettings`'s
    /// completion runs off the main actor, so it hops back before calling
    /// `completion` (same pattern as `refreshPermissionStatus` above).
    /// `.provisional`/`.ephemeral` (quiet delivery, still permitted) count as
    /// `.authorized` — the row is asking "will anything ever show up", not
    /// distinguishing delivery styles doctor/the row text don't cover.
    func currentPermissionState(completion: @escaping (NotificationPermissionState) -> Void) {
        guard let center else {
            Task { @MainActor in completion(.notDetermined) }
            return
        }
        center.getNotificationSettings { settings in
            let state: NotificationPermissionState
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                state = .authorized
            case .denied:
                state = .denied
            case .notDetermined:
                state = .notDetermined
            @unknown default:
                state = .notDetermined
            }
            Task { @MainActor in
                completion(state)
            }
        }
    }

    /// Whether this app process has consumed its first `.snapshot` event yet
    /// (DESIGN.md §4.5 addendum). Not persisted — a fresh launch always gets
    /// a fresh baseline, per process, as designed.
    private var hasConsumedFirstSnapshot = false

    /// Feed the latest known agents (from any source: snapshot,
    /// status_changed, or a post-reconcile refresh, §4.5) to detect rising
    /// edges and schedule their delayed notifications.
    func observe(agents: [Agent]) {
        for edge in edgeTracker.observe(agents: agents) {
            scheduleDelayedNotification(for: edge)
        }
    }

    /// Feed a `.snapshot` event specifically. The app layer's only
    /// responsibility for the baseline rule (DESIGN.md §4.5 addendum) is
    /// knowing *which* snapshot is first per process — the decision to
    /// suppress edges for it is pure logic in `UnreviewedEdgeTracker`.
    func observeSnapshot(agents: [Agent]) {
        let isBaseline = !hasConsumedFirstSnapshot
        hasConsumedFirstSnapshot = true
        for edge in edgeTracker.observe(agents: agents, baseline: isBaseline) {
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
        // Re-read both mute switches at the delayed re-check moment (same as
        // the unreviewed re-check above) so a toggle flipped during the 3s
        // delay is respected (§4.5/§8.14 2026-07-05 addendum).
        let decision = NotificationDeliveryPolicy.decide(muteBanners: isBannersMuted, muteSound: isMuted)

        guard decision.deliverBanner else {
            if decision.playStandaloneSound {
                playStandaloneAlertSound()
            }
            return
        }

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
        // Both waiting and done play the same standard sound (§4.5/§8.16).
        if decision.attachBannerSound {
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: "\(edge.target)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center?.add(request)
    }

    /// "Mute Banners only" ("sound-only mode", §4.5/§8.14 2026-07-05
    /// addendum): no `UNNotification` is delivered, so the app plays the
    /// system alert sound directly via `NSSound` instead. This intentionally
    /// does NOT follow Focus/Do Not Disturb — only a banner's attached
    /// `UNNotificationSound` respects that (§4.5). The user's configured
    /// alert sound is read the same way the system itself plays it: the
    /// `com.apple.sound.beep.sound` global-domain preference (confirmed on
    /// this machine via `defaults read -g com.apple.sound.beep.sound`,
    /// which returned a `/System/Library/Sounds/*.aiff` path). AppKit's
    /// `NSBeep()` would also play that same sound, but the SDK's
    /// AppKit.apinotes hides it from Swift (`SwiftPrivate: true` for the
    /// free-function form — checked in the installed Xcode SDK), so the
    /// fallback (only reached if the preference can't be resolved) plays a
    /// bundled system sound (`/System/Library/Sounds/Glass.aiff`) directly
    /// instead.
    private func playStandaloneAlertSound() {
        if let path = UserDefaults.standard.string(forKey: "com.apple.sound.beep.sound"),
           let sound = NSSound(contentsOfFile: path, byReference: true) {
            sound.play()
        } else {
            NSSound(named: "Glass")?.play()
        }
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
