// Central app state (DESIGN.md §4.5): owns the agent table (kept in sync via
// the daemon subscribe stream), drives reconcile at startup/reconnect,
// dispatches CLI subprocess calls for focus/rescan, wires `agent_removed`
// into notification cleanup, and owns the shared model of the popover and
// the window (`MainSurfaceModel`).

import AppKit
import Combine
import Foundation
import os
import ServiceManagement
import ShiibarCcCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var agents: [Agent] = [] {
        didSet {
            rememberObservedTerminal()
            surface.agentsUpdated(agents)
        }
    }
    @Published private(set) var connected = false {
        didSet { pushWarnings() }
    }
    /// Either focus, resume, or reconcile returned exit 3 (§4.5: not
    /// focus-only — a reconcile silenced by a missing Automation permission
    /// would silently lose the whole backstop).
    @Published var tccWarning = false {
        didSet { pushWarnings() }
    }
    /// Transient message-line text for a manually-triggered Rescan (§4.5/§9:
    /// "Rescanning…" while in flight, then "✓ Rescan done" / "Rescan failed"
    /// for `RescanFeedback.displaySeconds` before it clears). `nil` = show
    /// nothing. Only the manual ⌄-menu Rescan drives this — the automatic
    /// reconcile calls at startup/reconnect stay silent (§4.5).
    @Published private(set) var rescanFeedback: RescanFeedback? {
        didSet { surface.showRescanFeedback(rescanFeedback) }
    }
    /// Bumped every time `rescanFeedback` is set, so a stale clear-after-2s
    /// timer from an earlier run can recognize it's no longer current (e.g.
    /// the user re-ran Rescan while the previous "✓ Rescan done" was still
    /// fading out) and skip clearing a newer state out from under it.
    private var rescanFeedbackGeneration = 0
    /// Settings > General "Appearance" (§4.5/§8.30, M27 T5): System /
    /// Light / Dark, persisted in UserDefaults, applied as `NSApp.appearance` the moment it's picked
    /// and re-applied at launch (`start()`). The tray icon is a template
    /// image, so it keeps following the menu bar's own appearance
    /// regardless (§4.5).
    @Published private(set) var appearanceSetting: AppearanceSetting
    private static let appearanceKey = "cc.shiibar.appearance"

    let notificationManager: NotificationManager
    /// The text size of the popover and the window (§4.5 "text size"): a
    /// single shared store so the ⌘ keys and the Settings window's Text size
    /// field read and write the same live value.
    let textSize: TextSizeStore
    /// The one state shared by the popover and the window (§4.5).
    let surface: MainSurfaceModel
    /// The global hotkey (§4.5 "global hotkey"): registered in `start()`;
    /// the Settings window records its combination.
    let hotKey: GlobalHotKeyModel
    private let lifecycle: DaemonLifecycleManager
    /// Not `private`: the Setup Check window (§4.5, M5 T5) also needs it to
    /// run `shiibar-cc doctor --json` via `CLIRunner`, same as `focus` /
    /// `runReconcile` below.
    let helpersDirectory: URL?
    /// Drives periodic reconcile (§4.5/§8.22/§9): started once in `start()`,
    /// invalidated in `deinit`. The interval/tolerance values live in
    /// `PeriodicReconcile` (ShiibarCcCore) — the scheduler itself is
    /// AppKit-only and can't move there.
    private var periodicReconcileScheduler: NSBackgroundActivityScheduler?
    /// Drives the Conversations index warming (§4.6/§8.22/§9): kicked once at
    /// launch and then ~every 10 minutes so a `conversations search`'s
    /// catch-up stays small (interval/tolerance in `ConversationsIndexWarming`,
    /// ShiibarCcCore). NO FSEvents (§4.6).
    private var conversationsIndexScheduler: NSBackgroundActivityScheduler?
    var home: String? { ProcessInfo.processInfo.environment["HOME"] }

    /// Set by `MainSurfaceController`: the app menu's Close Window closes
    /// the popover while it is key, else the key window (§4.5).
    var closeKeySurface: () -> Void = { NSApp.keyWindow?.performClose(nil) }
    /// Set by `MainSurfaceController`: opening About / Settings / Setup
    /// Check closes the popover (§4.5 "popover" close triggers).
    var willOpenAuxiliaryWindow: () -> Void = {}
    /// Set by `MainSurfaceController`: Dock click / reopen raises the window.
    var raiseMainWindow: () -> Void = {}

    init(helpersDirectory: URL?) {
        self.helpersDirectory = helpersDirectory
        let notificationManager = NotificationManager()
        self.notificationManager = notificationManager
        let storedAppearance = UserDefaults.standard.string(forKey: Self.appearanceKey)
            .flatMap(AppearanceSetting.init(rawValue:))
        self.appearanceSetting = storedAppearance ?? AppearanceSetting.defaultSetting
        let textSize = TextSizeStore()
        self.textSize = textSize
        self.hotKey = GlobalHotKeyModel(registrar: CarbonHotKeyRegistrar(), defaults: .standard)
        let home = ProcessInfo.processInfo.environment["HOME"]
        self.surface = MainSurfaceModel(
            home: home,
            defaults: .standard,
            textSize: textSize,
            runCommand: { arguments, completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    // Exit 2 (Jump: no such tab) is an expected outcome.
                    let result = CLIRunner.run(arguments, helpersDirectory: helpersDirectory, expectedExitCodes: [0, 2])
                    Task { @MainActor in completion(result.exitCode) }
                }
            }
        )

        let root = StateDirectory.resolveRoot() ?? (NSHomeDirectory() + "/.local/state/shiibar-cc")
        self.lifecycle = DaemonLifecycleManager(
            socketPath: StateDirectory.socketPath(root: root),
            daemonLogPath: StateDirectory.daemonLogPath(root: root),
            helpersDirectory: helpersDirectory
        )

        notificationManager.currentAgentsProvider = { [weak self] in self?.agents ?? [] }
        notificationManager.homeProvider = { [weak self] in self?.home }
        notificationManager.onFocusRequested = { [weak self] target in
            self?.focus(target: target)
        }
        surface.helpersDirectory = helpersDirectory
        surface.resumeTerminal = { [weak self] in self?.resumeTerminal ?? ResumeTerminal.iterm2 }
        surface.onPermissionDenied = { [weak self] in self?.tccWarning = true }
        surface.onSurfaceShown = { [weak self] in
            // §4.5: re-evaluate the notification-permission warning row every
            // time the popover or the window shows (a permission changed in
            // System Settings mid-session shows without a restart).
            self?.notificationManager.refreshPermissionStatus()
        }
        notificationManager.$permissionDenied
            .removeDuplicates()
            .sink { [weak self] _ in
                // `$permissionDenied` emits before the property changes.
                DispatchQueue.main.async { self?.pushWarnings() }
            }
            .store(in: &subscriptions)
        pushWarnings()
    }

    private var subscriptions: Set<AnyCancellable> = []

    /// The fixed footer's warning rows (§4.5 "making failures visible").
    private func pushWarnings() {
        var warnings: [SurfaceWarning] = []
        if !connected { warnings.append(.disconnected) }
        if notificationManager.permissionDenied { warnings.append(.notificationsDenied) }
        if tccWarning { warnings.append(.automationPermission) }
        surface.setWarnings(warnings)
    }

    deinit {
        periodicReconcileScheduler?.invalidate()
        conversationsIndexScheduler?.invalidate()
    }

    // MARK: - Regular app while the window is open (§4.5/§8.30)

    /// The window opened: the app becomes a regular app (Dock, ⌘Tab, menu
    /// bar) for as long as it stays open.
    func noteRegularWindowOpened() {
        switchToRegularApp()
    }

    /// The window closed: back to the resident accessory app. No activation
    /// dance on the way down — the system hands focus (and the menu bar) to
    /// another app by itself.
    func noteRegularWindowClosed() {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Flip the app to a regular app for as long as a window exists
    /// (§4.5/§8.30, M27 T1). Ordering measured on-device (macOS 14 harness,
    /// M27): after flipping an already-active app to `.regular` the menu bar
    /// keeps showing the PREVIOUS app's menus even though `NSApp.isActive` is
    /// true. Neither activate-after-policy (a no-op while active),
    /// deactivate+activate, nor a next-turn activate refreshes it. The one
    /// reliable order: set the policy, hand activation to another app (the
    /// Dock — always running, shows no menu bar of its own), then take it
    /// back a beat later.
    private func switchToRegularApp() {
        NSApp.setActivationPolicy(.regular)
        if let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock").first {
            dock.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            // No Dock process to bounce through (not seen in practice) —
            // degrade to a plain activate: the app still becomes regular,
            // at worst the menu bar lags until the next app switch.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func start() {
        // §4.5 (M27 T5): re-apply the persisted appearance at launch.
        applyAppearance()
        // §4.5 "global hotkey": register the stored combination (M45 T1).
        hotKey.start()
        notificationManager.requestAuthorizationIfNeeded()
        lifecycle.onConnectedChanged = { [weak self] isConnected in
            self?.connected = isConnected
            if isConnected {
                // §4.5: reconcile on startup and on every reconnect
                // (post-snapshot self-repair of daemon-absence gaps).
                self?.runReconcile()
            }
        }
        lifecycle.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
        lifecycle.start()
        schedulePeriodicReconcile()
        scheduleConversationsIndexWarming()
        kickConversationsIndexWarming()
    }

    /// Start the §4.5/§8.22 periodic reconcile: an `NSBackgroundActivityScheduler`
    /// (interval/tolerance from `PeriodicReconcile`, ShiibarCcCore) that calls
    /// `runReconcile(showFeedback: false)` on the cadence in DESIGN.md §9.
    /// Started once here at app launch; the OS scheduler owns "don't run
    /// while asleep" (§8.22 — no custom screen-state/sleep detection is
    /// written here; the activity simply doesn't fire during sleep and
    /// resumes naturally on wake).
    ///
    /// The scheduler's block runs on its own background queue (not the main
    /// actor), so the reconcile call is hopped onto `@MainActor` the same
    /// way every other AppState entry point is. `completionHandler` is
    /// invoked only after the reconcile subprocess actually finishes
    /// (`runReconcile`'s completion callback) — per `NSBackgroundActivityScheduler`
    /// docs, failing to call it would stop the activity from ever
    /// rescheduling, silently ending the repeats.
    private func schedulePeriodicReconcile() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "cc.shiibar.menubar.reconcile")
        scheduler.interval = PeriodicReconcile.intervalSeconds
        scheduler.tolerance = PeriodicReconcile.toleranceSeconds
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completionHandler in
            guard let self else {
                completionHandler(.finished)
                return
            }
            Task { @MainActor in
                self.runReconcile(showFeedback: false) {
                    completionHandler(.finished)
                }
            }
        }
        periodicReconcileScheduler = scheduler
    }

    /// Start the §4.6/§8.22 Conversations index warming: an
    /// `NSBackgroundActivityScheduler` (interval/tolerance from
    /// `ConversationsIndexWarming`, ShiibarCcCore) that runs
    /// `conversations index` on the §9 ~10-minute cadence so a search's
    /// catch-up stays small. Same flow as `schedulePeriodicReconcile` above;
    /// the OS scheduler owns "don't run while asleep" (§8.22). NO FSEvents —
    /// display freshness is driven by user actions, not file watching (§4.6).
    private func scheduleConversationsIndexWarming() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "cc.shiibar.menubar.conversations-index")
        scheduler.interval = ConversationsIndexWarming.intervalSeconds
        scheduler.tolerance = ConversationsIndexWarming.toleranceSeconds
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completionHandler in
            guard let self else {
                completionHandler(.finished)
                return
            }
            Task { @MainActor in
                self.runConversationsIndexWarming { completionHandler(.finished) }
            }
        }
        conversationsIndexScheduler = scheduler
    }

    /// Kick one index warming right at launch (§4.6: "at app launch"),
    /// independent of the scheduler's first fire.
    private func kickConversationsIndexWarming() {
        runConversationsIndexWarming(completion: nil)
    }

    /// Run `conversations index` (no `--json` — this is background warming,
    /// not a progress-reporting open). Failure is quiet: log only (§4.6). The
    /// popover / window open flow runs `index --json` for visible progress
    /// (`MainSurfaceModel`).
    /// `completion` is called after the subprocess finishes so the scheduler
    /// can hand `NSBackgroundActivityScheduler` its completion handler.
    private func runConversationsIndexWarming(completion: (() -> Void)?) {
        DispatchQueue.global(qos: .utility).async { [helpersDirectory] in
            // Both exit 0 (indexed) and 1 (build failed) are acceptable
            // outcomes for a silent warmer — neither should error-log beyond
            // CLIRunner's own line, so mark both expected.
            _ = CLIRunner.run(
                ["conversations", "index"],
                helpersDirectory: helpersDirectory,
                expectedExitCodes: [0, 1]
            )
            if let completion {
                Task { @MainActor in completion() }
            }
        }
    }

    func handle(event: SubscribeEvent) {
        switch event {
        case .snapshot(let snapshotAgents):
            agents = snapshotAgents
            notificationManager.observeSnapshot(agents: agents)
        case .statusChanged(let agent):
            if let index = agents.firstIndex(where: { $0.target == agent.target }) {
                agents[index] = agent
            } else {
                agents.append(agent)
            }
            notificationManager.observe(agents: agents)
            if !agent.unreviewed {
                notificationManager.sweepDelivered(target: agent.target)
            }
        case .agentRemoved(let target, let reason):
            agents.removeAll { $0.target == target }
            notificationManager.forget(target: target)
            notificationManager.sweepDelivered(target: target, reason: reason)
        case .unknown:
            break
        }
    }

    // MARK: - Resume terminal (§4.6/T6)

    /// Remember the newest observed terminal kind so Resume can fall back to
    /// it once the agent list empties (§4.6: "updated every time entries are
    /// observed"). Only stores when the current entries name a supported
    /// terminal — an empty/unrecognized list leaves the previous memory
    /// intact.
    private func rememberObservedTerminal() {
        if let kind = ResumeTerminal.newestObservedKind(agents: agents) {
            UserDefaults.standard.set(kind, forKey: ResumeTerminal.userDefaultsKey)
        }
    }

    /// The `--terminal` value Resume should pass (§4.6/T6): newest observed
    /// entry's kind → remembered kind → `iterm2`.
    var resumeTerminal: String {
        ResumeTerminal.decide(
            agents: agents,
            remembered: UserDefaults.standard.string(forKey: ResumeTerminal.userDefaultsKey)
        )
    }

    // MARK: - Derived display state

    /// ⌄ menu "Clear badges" enabled state (§4.5/§8.24): disabled when no
    /// agent currently carries the unreviewed flag.
    var hasUnreviewed: Bool {
        agents.contains { $0.unreviewed }
    }

    var trayIcon: TrayIconState {
        Rollup.icon(
            statuses: agents.map(\.status),
            hasUnreviewed: agents.contains { $0.unreviewed },
            daemonConnected: connected
        )
    }

    /// Settings "Appearance" pick (§4.5, M27 T5): applied the moment it's
    /// selected (no "OK to confirm", §8.26), persisted for the launch-time
    /// re-apply in `start()`.
    func setAppearanceSetting(_ setting: AppearanceSetting) {
        appearanceSetting = setting
        UserDefaults.standard.set(setting.rawValue, forKey: Self.appearanceKey)
        applyAppearance()
    }

    /// §4.5: System = `NSApp.appearance = nil` (follow the OS); Light /
    /// Dark pin the whole app — popover, window, Settings, Setup Check — to aqua / darkAqua. The name strings live in
    /// `AppearanceSetting` (ShiibarCcCore) where a unit test pins them to
    /// the real `NSAppearance.Name` constants.
    private func applyAppearance() {
        if let rawName = appearanceSetting.nsAppearanceNameRawValue {
            NSApp.appearance = NSAppearance(named: NSAppearance.Name(rawName))
        } else {
            NSApp.appearance = nil
        }
    }

    // MARK: - Actions (§8.4: only read/jump/refresh/UX-setting verbs live here)

    /// Raise the TCC warning row when a subprocess reported exit 3 (§4.5).
    /// The nonzero-exit os_log line is emitted centrally by CLIRunner.
    private func noteExitCode(_ exitCode: Int32) {
        if exitCode == 3 {
            tccWarning = true
        }
    }

    /// Focus a terminal tab on a notification click (§4.5). The shared TCC
    /// (exit 3) handling in `noteExitCode` raises the warning row;
    /// `completion` runs on the main actor after the subprocess returns;
    /// `seen`-on-success stays the CLI's job. (The list's Jump runs through
    /// `MainSurfaceModel`'s row-verb runner.)
    func focus(target: String, completion: (@MainActor (Int32) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, helpersDirectory] in
            let result = CLIRunner.focus(target: target, helpersDirectory: helpersDirectory)
            Task { @MainActor [weak self] in
                self?.noteExitCode(result.exitCode)
                completion?(result.exitCode)
            }
        }
    }

    /// ⌄ menu "Clear badges" (§4.5/§8.24): calls `shiibar-cc seen <target>`
    /// for every currently-unreviewed target. No feedback UI on success —
    /// the badges disappearing (via the subscribe stream's `status_changed`
    /// events, same path as any other state change) IS the feedback. Only
    /// the unreviewed flag is touched; delivered Notification Center
    /// notifications are left alone (§8.24 — the user clears those
    /// themselves).
    func clearBadges() {
        let targets = agents.filter(\.unreviewed).map(\.target)
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [helpersDirectory] in
            for target in targets {
                CLIRunner.seen(target: target, helpersDirectory: helpersDirectory)
            }
        }
    }

    /// Reconcile via the CLI (§3.5/§4.5). Reached from all three trigger
    /// paths — startup, daemon reconnect (`onConnectedChanged`), and the ⌄
    /// menu's Rescan — so a permission failure surfaces even before the
    /// user ever clicks anything.
    ///
    /// `showFeedback`: only the manual ⌄-menu Rescan passes `true` — §4.5
    /// scopes the transient feedback to the manual trigger, so the
    /// automatic startup/reconnect/periodic calls stay silent.
    ///
    /// `completion`: called after the subprocess finishes (any exit code),
    /// on the main actor. Only the periodic reconcile scheduler
    /// (`schedulePeriodicReconcile`) passes this — it needs to know when the
    /// run is done to hand `NSBackgroundActivityScheduler` its completion
    /// handler. `nil` for every other caller.
    ///
    /// Overlapping-run guard: a second manual Rescan while one is already
    /// running is ignored (simpler than cancelling the in-flight subprocess
    /// or restarting its feedback timer) — reconcile is idempotent, so a
    /// duplicate tap during an in-flight run loses nothing but an extra
    /// subprocess launch; the in-flight run still resyncs state and reports
    /// its own feedback when it finishes. The same idempotency is why the
    /// periodic scheduler's own cadence needs no additional serialization
    /// against these other triggers (§4.5 task brief).
    func runReconcile(showFeedback: Bool = false, completion: (() -> Void)? = nil) {
        if showFeedback {
            guard rescanFeedback != .running else { return }
            showRescanFeedback(.running)
        }
        DispatchQueue.global(qos: .utility).async { [weak self, helpersDirectory] in
            let result = CLIRunner.reconcile(helpersDirectory: helpersDirectory)
            Task { @MainActor [weak self] in
                self?.noteExitCode(result.exitCode)
                if showFeedback {
                    if let feedback = RescanFeedback.forFinishedExitCode(result.exitCode) {
                        self?.showRescanFeedback(feedback)
                    } else {
                        // Exit 3 (TCC): the warning row is already handling
                        // it (via `noteExitCode` above) — clear
                        // "Rescanning…" immediately rather than flashing
                        // transient text too.
                        self?.rescanFeedback = nil
                    }
                }
                completion?()
            }
        }
    }

    /// Set `rescanFeedback` and, for a terminal state, schedule its
    /// clear-after-`displaySeconds`. The generation check in the scheduled
    /// closure keeps a stale timer from an earlier run from clearing a
    /// feedback state that a newer run has since replaced.
    private func showRescanFeedback(_ feedback: RescanFeedback) {
        rescanFeedbackGeneration += 1
        let generation = rescanFeedbackGeneration
        rescanFeedback = feedback
        guard feedback != .running else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + RescanFeedback.displaySeconds) { [weak self] in
            guard let self, self.rescanFeedbackGeneration == generation else { return }
            self.rescanFeedback = nil
        }
    }

    /// "Start at Login" checkmark, read by the Settings window (§4.5, M14
    /// T2) — read live, never cached — `SMAppService.mainApp.status` is the
    /// sole source of truth so the checkmark can't drift from System
    /// Settings' own Login Items UI.
    var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// "Start at Login" toggle, driven by the Settings window (§4.5, M14
    /// T2; moved out of the ⌄ menu, M5 T3 originally): register/unregister
    /// directly via `SMAppService` — no local flag is written here (that's
    /// only for the one-time launch auto-registration, §4.5/T3-A). Failures
    /// are logged, not surfaced as an alert (§4.5's "don't swallow
    /// failures" rule, same pattern as `CLIRunner`'s subprocess logging) —
    /// this is a settings toggle, not a user-blocking action.
    func toggleLoginItem() {
        do {
            if loginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            loginItemLog.error(
                "Start at Login toggle failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// ⌄ menu "Quit": stop the daemon, then the app (§4.5/§8.8) — but Quit
    /// must ALWAYS terminate the app, promptly, no matter what state the
    /// daemon connection is in (a dead daemon made the old
    /// wait-for-shutdown-ack path hang forever, leaving the app unquittable
    /// — seen on-device).
    ///
    /// Disconnected: there is nothing to shut down (the daemon is already
    /// gone or unreachable) — terminate immediately.
    /// Connected: send `shutdown` best-effort. `sendOneShot` itself has a
    /// 1.5s internal timeout, and a 2s main-queue hard deadline here
    /// guarantees termination even if that path stalls entirely; whichever
    /// fires first wins (the loser never runs — the process is gone).
    func quit() {
        guard connected else {
            NSApplication.shared.terminate(nil)
            return
        }
        lifecycle.shutdown {
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Fire-and-forget daemon shutdown for a termination path that didn't
    /// originate from the menu's Quit (e.g. `applicationShouldTerminate`
    /// being invoked directly) — doesn't itself call `terminate(nil)` again,
    /// to avoid re-entering the termination sequence.
    func bestEffortShutdownDaemon() {
        lifecycle.shutdown {}
    }
}

/// os_log sink for Login Item toggle diagnostics. Same subsystem/category
/// convention as `ShiibarCcMenuBarApp`'s auto-registration logger and
/// `CLIRunner`'s subprocess logger.
///   log show --last 1h --predicate 'subsystem == "cc.shiibar.menubar" AND category == "login-item"'
private let loginItemLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.shiibar.menubar",
    category: "login-item"
)
