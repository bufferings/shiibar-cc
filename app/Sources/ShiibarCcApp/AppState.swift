// Central app state (DESIGN.md §4.5): owns the agent table (kept in sync via
// the daemon subscribe stream), drives reconcile at startup/reconnect,
// dispatches CLI subprocess calls for focus/reconcile, wires `agent_removed`
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
    /// Settings > General > Terminal (§4.5/§4.6): where Resume and Branch
    /// open, and whether that terminal can be used.
    let resumeTerminal: ResumeTerminalSetting
    private let lifecycle: DaemonLifecycleManager
    /// Not `private`: the Setup Check tab (§4.5) also needs it to run
    /// `shiibar-cc doctor --json` via `CLIRunner`, same as `focus` /
    /// `runReconcile` below.
    let helpersDirectory: URL?
    /// The Settings window's tabs and models (§4.5 "Settings window"),
    /// created on first use and kept for the app's lifetime, like the
    /// window scene that shows it.
    lazy var settingsWindow: SettingsWindowModel = {
        let notificationManager = notificationManager
        let helpersDirectory = helpersDirectory
        return SettingsWindowModel(
            general: SettingsViewModel(
                notificationManager: notificationManager,
                loginItemEnabledProvider: { [weak self] in self?.loginItemEnabled ?? false },
                toggleLoginItem: { [weak self] in self?.toggleLoginItem() },
                appearanceSetting: appearanceSetting,
                setAppearance: { [weak self] in self?.setAppearanceSetting($0) }),
            textSizeField: TextSizeFieldModel(store: textSize),
            hotKey: hotKey,
            setupCheck: SetupCheckViewModel(
                helpersDirectory: helpersDirectory,
                notificationManager: notificationManager,
                loginItemEnabledProvider: { [weak self] in self?.loginItemEnabled ?? false }),
            resumeTerminal: resumeTerminal)
    }()
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
    /// Set by `MainSurfaceController`: opening About / Settings closes the
    /// popover (§4.5 "popover" close triggers).
    var willOpenAuxiliaryWindow: () -> Void = {}
    /// Set by `MainSurfaceController`: Dock click / reopen raises the window.
    var raiseMainWindow: () -> Void = {}
    /// Set by `MainSurfaceController`: shows the About panel and gives it
    /// the level the window pin calls for (`AuxiliaryWindowLevel`).
    var showAboutPanel: () -> Void = { NSApp.orderFrontStandardAboutPanel(nil) }
    /// Set by `MainSurfaceController`: a notification click on a session
    /// the app cannot jump to opens the surface of the current form, then
    /// selects the session's Running row (§4.5 "notification click").
    var showRowForNotification: (String) -> Void = { _ in }

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
        // §4.5 "Settings window" > Terminal: the first value is decided and
        // the old key removed here, at app launch.
        let resumeTerminal = ResumeTerminalSetting(
            defaults: .standard, lookup: InstalledTerminalApps.live, center: .default)
        self.resumeTerminal = resumeTerminal
        let home = ProcessInfo.processInfo.environment["HOME"]
        self.surface = MainSurfaceModel(
            home: home,
            defaults: .standard,
            textSize: textSize,
            runCommand: { arguments, completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    // Exit 2 (Jump: no such tab) is an expected outcome of
                    // the row verbs; any failure of Refresh's reconcile
                    // silently loses the backstop and must error-log
                    // (`CLIRunner.reconcile`).
                    let expected: Set<Int32> = arguments == CLIRunner.reconcileArguments ? [0] : [0, 2]
                    let result = CLIRunner.run(arguments, helpersDirectory: helpersDirectory, expectedExitCodes: expected)
                    Task { @MainActor in completion(result.exitCode) }
                }
            }
        )

        let root = StateDirectory.resolveRoot() ?? (NSHomeDirectory() + "/.local/state/shiibar-cc")
        self.lifecycle = DaemonLifecycleManager(
            socketPath: StateDirectory.socketPath(root: root),
            daemonLogPath: StateDirectory.daemonLogPath(root: root),
            helpersDirectory: helpersDirectory,
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )

        notificationManager.currentAgentsProvider = { [weak self] in self?.agents ?? [] }
        notificationManager.homeProvider = { [weak self] in self?.home }
        notificationManager.onFocusRequested = { [weak self] target in
            self?.focus(target: target)
        }
        notificationManager.onSelectRowRequested = { [weak self] target in
            self?.showRowForNotification(target)
        }
        surface.helpersDirectory = helpersDirectory
        surface.onPermissionDenied = { [weak self] in self?.tccWarning = true }
        surface.onSurfaceShown = { [weak self] in
            // §4.5: re-evaluate the notification-permission warning row every
            // time the popover or the window shows (a permission changed in
            // System Settings mid-session shows without a restart).
            self?.notificationManager.refreshPermissionStatus()
        }
        // §4.5 "Settings window" > Terminal / §4.6 "Resume and Branch":
        // `--terminal`, the buttons' enabled state, and the re-check on
        // every surface show.
        resumeTerminal.attach(to: surface)
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

    /// What keeps the app regular: the window, or the popover `Open in
    /// popover` opened (`RegularAppHold`).
    private(set) var regularAppHold = RegularAppHold()

    /// The window opened: the app becomes a regular app (Dock, ⌘Tab, menu
    /// bar) for as long as it stays open — unless it already is (the window
    /// opened from the popover `Open in popover` opened).
    func noteRegularWindowOpened() {
        apply(regularAppHold.windowOpened())
    }

    /// The window closed. `forOpenInPopover`: the app stays regular while
    /// the popover that operation opens is shown (§4.5: returning to
    /// accessory while it is shown may deactivate the app, which would close
    /// that popover).
    /// Otherwise back to the resident accessory app at once. No activation
    /// dance on the way down — the system hands focus (and the menu bar) to
    /// another app by itself.
    func noteRegularWindowClosed(forOpenInPopover: Bool) {
        apply(regularAppHold.windowClosed(forOpenInPopover: forOpenInPopover))
    }

    /// The popover closed: back to accessory when it was the popover `Open
    /// in popover` opened.
    func notePopoverClosed() {
        apply(regularAppHold.popoverClosed())
    }

    private func apply(_ effect: RegularAppHold.Effect?) {
        switch effect {
        case .switchToRegular:
            switchToRegularApp()
        case .switchToAccessory:
            NSApp.setActivationPolicy(.accessory)
        case nil:
            break
        }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                // The window can be closed within this delay (the same key
                // opens and closes it): never leave the app active with no
                // window.
                MainActor.assumeIsolated {
                    guard let self, self.regularAppHold.allowsDeferredActivation else { return }
                    NSApp.activate(ignoringOtherApps: true)
                }
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
    /// `runReconcile` on the cadence in DESIGN.md §9.
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
                self.runReconcile {
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
        case .agentRemoved(let target, let reason, let to):
            switch AgentRemovalHandling.decide(reason: reason, to: to) {
            case .rekey(let to):
                // §4.5 "desktop notifications": a target change, not a
                // removal. The fired record, a pending delayed notification,
                // the row's selection and the conversation pane move to
                // `to`; delivered notifications stay. The list hears of it
                // before the table changes, so the row is never treated as
                // gone.
                Self.applyRekey(
                    from: target, to: to, agents: agents,
                    notifications: { [notificationManager] in notificationManager.rekey(from: $0, to: $1) },
                    list: { [surface] in surface.targetRekeyed(from: $0, to: $1) },
                    setAgents: { [weak self] in self?.agents = $0 })
            case .remove(let sweepReason):
                agents.removeAll { $0.target == target }
                notificationManager.forget(target: target)
                notificationManager.sweepDelivered(target: target, reason: sweepReason)
            }
        case .unknown:
            break
        }
    }

    /// The order of a `rekey` (§4.5 "desktop notifications"): the
    /// notifications first, then the list, then the agent table (whose
    /// change the list hears through `agentsUpdated`), so the list never
    /// sees the entry missing from the table before it knows of the move.
    static func applyRekey(
        from: String, to: String, agents: [Agent],
        notifications: (String, String) -> Void,
        list: (String, String) -> Void,
        setAgents: ([Agent]) -> Void
    ) {
        notifications(from, to)
        list(from, to)
        setAgents(AgentRemovalHandling.agentsAfterRekey(agents, from: from, to: to))
    }

    // MARK: - Derived display state

    /// ⌄ menu "Mark all as read" enabled state (§4.5/§8.24): disabled when
    /// no agent currently carries the unreviewed flag.
    var hasUnreviewed: Bool {
        MarkAllAsRead.isEnabled(agents: agents)
    }

    var trayIcon: TrayIconState {
        Rollup.icon(agents: agents, daemonConnected: connected)
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
    /// Dark pin the whole app — popover, window, Settings — to aqua / darkAqua. The name strings live in
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

    /// ⌄ menu "Mark all as read" (§4.5/§8.24): calls `shiibar-cc seen
    /// <target>` for every currently-unreviewed target. No feedback UI on
    /// success — the accent-color dots disappearing (via the subscribe
    /// stream's `status_changed` events, same path as any other state
    /// change) IS the feedback; a waiting session's orange stays until it
    /// stops waiting (§3.1). Only the unreviewed flag is touched; delivered
    /// Notification Center notifications are left alone (§8.24 — the user
    /// clears those themselves).
    func markAllAsRead() {
        // The same `seen` path as the lasting selection (§4.5), so a `rekey`
        // while one runs resends it to the new target.
        for target in MarkAllAsRead.targets(agents: agents) {
            surface.markRead(target: target)
        }
    }

    /// Reconcile via the CLI (§3.5/§4.5 "running reconcile") for the
    /// startup, daemon reconnect (`onConnectedChanged`) and periodic
    /// triggers, so a permission failure surfaces even before the user ever
    /// clicks anything. These runs show no transient on the message line;
    /// exit 3 raises the warning row (§4.5). Refresh runs its own reconcile
    /// through `MainSurfaceModel` (§4.6).
    ///
    /// `completion`: called after the subprocess finishes (any exit code),
    /// on the main actor. Only the periodic reconcile scheduler
    /// (`schedulePeriodicReconcile`) passes this — it needs to know when the
    /// run is done to hand `NSBackgroundActivityScheduler` its completion
    /// handler. Reconcile is idempotent, so overlapping runs from different
    /// triggers need no serialization.
    func runReconcile(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self, helpersDirectory] in
            let result = CLIRunner.reconcile(helpersDirectory: helpersDirectory)
            Task { @MainActor [weak self] in
                self?.noteExitCode(result.exitCode)
                completion?()
            }
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
