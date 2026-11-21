// Desktop notifications (DESIGN.md §4.5/§8.16/§8.26/§8.27): UNUserNotification-
// Center, fired on the unreviewed rising edge, delayed 3s with an
// unreviewed-only re-check (no foreground suppression — dropped in M5,
// §8.16), a per-event (Waiting/Done) standard sound chosen in the Settings
// window and attached via `UNNotificationSound(named:)` so playback follows
// Focus/DND (§8.27), threadIdentifier grouping per target, one mute toggle
// (UserDefaults: Mute Sound — Mute Banners was removed in M14, §8.27), and
// cleanup that skips `session_end` removals. The first `.snapshot` this
// process receives is a baseline: pre-existing unreviewed entries in it
// don't notify (§4.5 2026-07-05 addendum) — see `observeSnapshot`.
// Rising-edge detection / de-dup / baseline seeding / the delayed decision /
// content building / the sound-name decision / the cleanup rule are pure
// logic in ShiibarCcCore (`UnreviewedEdgeTracker`, `DelayedNotificationDecision`,
// `NotificationContentBuilder`, `NotificationSoundPolicy`,
// `NotificationCleanupRule`) — this type is the I/O wrapper around them.

import Foundation
import UserNotifications
import ShiibarCcCore

/// Delay before the re-check-and-maybe-fire (§4.5/§9: 3 seconds).
private let delaySeconds: TimeInterval = 3

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private let edgeTracker = UnreviewedEdgeTracker()
    /// Old target -> new target of every `rekey` (§4.5 "desktop
    /// notifications"); kept until the app quits.
    private var rekeys = TargetRekeyMap()
    /// Called (main actor) when a notification of a session the app can jump
    /// to is clicked, to focus that target.
    var onFocusRequested: ((String) -> Void)?
    /// Called (main actor) when a notification of a session the app cannot
    /// jump to is clicked: open the surface and select its Running row
    /// (§4.5 "notification click").
    var onSelectRowRequested: ((String) -> Void)?
    /// Reflects the current authorization status for the "denied" warning row (§4.5).
    @Published private(set) var permissionDenied = false

    /// "Mute Sound" (§4.5/§8.27): the key predates the Settings window (M5
    /// §8.14 2026-07-05 addendum) — kept unchanged for compatibility (M14
    /// task brief) so an existing installation's choice carries over.
    private static let muteKey = "cc.shiibar.muteSound"
    var isMuted: Bool {
        get { defaults.bool(forKey: Self.muteKey) }
        set { defaults.set(newValue, forKey: Self.muteKey) }
    }

    /// Settings window's "Waiting sound" / "Done sound" pickers (§4.5/§8.26):
    /// the macOS standard sound name (extension-stripped, `SoundCatalog`) to
    /// attach to a waiting / done notification's banner. Defaults to
    /// `SoundCatalog.defaultSoundName` ("Glass") for both, unchanged from
    /// the pre-M14 behavior, until the user picks something else.
    private static let waitingSoundNameKey = "cc.shiibar.waitingSoundName"
    private static let doneSoundNameKey = "cc.shiibar.doneSoundName"
    var waitingSoundName: String {
        get { defaults.string(forKey: Self.waitingSoundNameKey) ?? SoundCatalog.defaultSoundName }
        set { defaults.set(newValue, forKey: Self.waitingSoundNameKey) }
    }
    var doneSoundName: String {
        get { defaults.string(forKey: Self.doneSoundNameKey) ?? SoundCatalog.defaultSoundName }
        set { defaults.set(newValue, forKey: Self.doneSoundNameKey) }
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

    /// Where a delivered notification goes, and how delivered ones are
    /// removed (by thread identifier = target). Production: the
    /// notification center; tests inject spies so nothing reaches it.
    struct Delivery {
        var post: @MainActor (_ request: UNNotificationRequest) -> Void
        var removeDelivered: @MainActor (_ threadIdentifier: String) -> Void
    }

    private let defaults: UserDefaults
    private let scheduleAfter: (_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void
    private var delivery: Delivery?

    /// `delivery` nil = the system notification center. `scheduleAfter`
    /// runs the delayed re-check (§4.5: 3 seconds); injected for tests.
    init(
        defaults: UserDefaults = .standard,
        scheduleAfter: @escaping (_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void
            = MainSurfaceModel.scheduleOnMain,
        delivery: Delivery? = nil
    ) {
        self.defaults = defaults
        self.scheduleAfter = scheduleAfter
        self.delivery = delivery
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
    /// for the Setup Check tab's row (§4.5). `getNotificationSettings`'s
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
        noteCurrentTargets(agents)
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
        noteCurrentTargets(agents)
        for edge in edgeTracker.observe(agents: agents, baseline: isBaseline) {
            scheduleDelayedNotification(for: edge)
        }
    }

    /// Every target in the table is a current target: a former target an
    /// entry is registered or reported under again (a new session reusing
    /// an old `process:<pid>`) stops being redirected by the `rekey` map.
    private func noteCurrentTargets(_ agents: [Agent]) {
        for agent in agents {
            rekeys.targetIsCurrent(agent.target)
        }
    }

    /// A target dropped out of the tracked set entirely (removed) — forget
    /// it so a future re-registration under the same target is a fresh edge.
    func forget(target: String) {
        edgeTracker.forget(target: target)
    }

    /// The daemon moved an entry from `from` to `to` (`agent_removed` with
    /// reason `rekey` — §4.5 "desktop notifications"): the fired record
    /// moves with it (no new notification for the same rise), a pending
    /// delayed notification re-checks the new target, and a click on a
    /// notification delivered before reads its target as the new one.
    /// Delivered notifications are not removed by the rekey itself; a later
    /// sweep of the entry removes them under the old target too.
    func rekey(from: String, to: String) {
        edgeTracker.rekey(from: from, to: to)
        rekeys.record(from: from, to: to)
    }

    private func scheduleDelayedNotification(for edge: UnreviewedEdge) {
        scheduleAfter(delaySeconds) { [weak self] in
            guard let self else { return }
            // The entry may have moved to another target meanwhile (`rekey`):
            // re-check, and deliver for, its current target.
            let target = self.rekeys.resolve(edge.target)
            // Re-check at fire time (§4.5): only the "still unreviewed?"
            // condition gates delivery now — foreground suppression was
            // dropped in M5 (§8.16), so there's no subprocess probe here
            // anymore, just a synchronous read of the live agent table.
            let agents = self.currentAgentsProvider()
            guard DelayedNotificationDecision.shouldNotify(
                currentlyUnreviewed: agents.contains(where: { $0.target == target && $0.unreviewed })
            ) else { return }
            guard let agent = agents.first(where: { $0.target == target }) else { return }
            self.deliver(edge: UnreviewedEdge(target: target, status: edge.status), agent: agent)
        }
    }

    /// Supplied by `AppState` so the delayed re-check and notification
    /// content both see live data rather than a stale capture from
    /// scheduling time.
    var currentAgentsProvider: () -> [Agent] = { [] }

    /// `$HOME`, used to render the same cwd label a list row's label line
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
        // Mute Banners is gone (§8.27): the banner is always delivered now,
        // so only the attached sound is decided here — re-read at the
        // delayed re-check moment (same as the unreviewed re-check above) so
        // a Settings change made during the 3s delay is respected.
        if let soundName = NotificationSoundPolicy.soundName(
            status: edge.status,
            waitingSoundName: waitingSoundName,
            doneSoundName: doneSoundName,
            muted: isMuted
        ) {
            // `<name>.aiff` resolves macOS standard sounds even though the
            // SDK header (UserNotifications/UNNotificationSound.h) only
            // documents the app container / bundle lookup and never mentions
            // /System/Library/Sounds — verified on a real install: a
            // notification delivered with "Submarine.aiff" audibly played
            // Submarine (DESIGN.md §4.5).
            content.sound = UNNotificationSound(named: UNNotificationSoundName("\(soundName).aiff"))
        }
        let request = UNNotificationRequest(
            identifier: "\(edge.target)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        if let delivery {
            delivery.post(request)
        } else {
            center?.add(request)
        }
    }

    /// Sweep delivered notifications for `target`, unless the reason forbids
    /// it (§4.2/§4.5: `session_end` must not wipe an unread completion toast).
    func sweepDelivered(target: String, reason: RemovalReason) {
        guard NotificationCleanupRule.shouldSweep(onRemovalReason: reason) else { return }
        sweepDelivered(target: target)
    }

    /// Sweep on focus / unreviewed-lowered (no removal reason involved).
    /// Notifications delivered under the entry's earlier targets (every
    /// former target the `rekey` map resolves to `target`) go too.
    func sweepDelivered(target: String) {
        let threads = [target] + rekeys.sources(resolvingTo: target)
        if let delivery {
            for thread in threads {
                delivery.removeDelivered(thread)
            }
            return
        }
        guard let center else { return }
        let threadSet = Set(threads)
        center.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { threadSet.contains($0.request.content.threadIdentifier) }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            // `center` is the process-wide singleton; re-fetch it here
            // because this completion handler runs off the main actor.
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: ids)
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
            self.notificationClicked(threadIdentifier: target)
            completionHandler()
        }
    }

    /// A click on a delivered notification (§4.5 "notification click"): its
    /// target (the thread identifier) is read through the `rekey` map, then
    /// a target the app can jump to is focused and any other one has its
    /// Running row selected.
    func notificationClicked(threadIdentifier: String) {
        switch NotificationClickAction.decide(target: rekeys.resolve(threadIdentifier)) {
        case .focus(let target):
            onFocusRequested?(target)
        case .selectRow(let target):
            onSelectRowRequested?(target)
        }
    }
}
