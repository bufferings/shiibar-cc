// Central app state (DESIGN.md §4.5): owns the agent table (kept in sync via
// the daemon subscribe stream), drives reconcile at startup/reconnect,
// dispatches CLI subprocess calls for focus/back/rescan, and wires
// `agent_removed` into notification cleanup.

import AppKit
import Combine
import Foundation
import os
import ServiceManagement
import ShiibarCcCore

@MainActor
final class AppState: ObservableObject {
    /// The working animation timer (M5 T8) only cares whether the current
    /// rollup shows `working`, so both mutation points refresh it.
    @Published private(set) var agents: [Agent] = [] {
        didSet { refreshWorkingAnimationTimer() }
    }
    @Published private(set) var connected = false {
        didSet { refreshWorkingAnimationTimer() }
    }
    /// Either focus or reconcile returned exit 3 (§4.5: not focus-only — a
    /// reconcile silenced by a missing Automation permission would silently
    /// lose the whole backstop).
    @Published var tccWarning = false
    /// Transient topbar text for a manually-triggered Rescan (§4.5/§9:
    /// "Rescanning…" while in flight, then "✓ Rescan done" / "Rescan failed"
    /// for `RescanFeedback.displaySeconds` before it clears). `nil` = show
    /// nothing. Only the manual ⌄-menu Rescan drives this — the automatic
    /// reconcile calls at startup/reconnect stay silent (§4.5).
    @Published private(set) var rescanFeedback: RescanFeedback?
    /// Bumped every time `rescanFeedback` is set, so a stale clear-after-2s
    /// timer from an earlier run can recognize it's no longer current (e.g.
    /// the user re-ran Rescan while the previous "✓ Rescan done" was still
    /// fading out) and skip clearing a newer state out from under it.
    private var rescanFeedbackGeneration = 0
    /// Elapsed-time base for the dropdown (DESIGN.md §4.5): captured when
    /// the dropdown opens, fixed while it stays open, refreshed on reopen.
    /// See `observeDropdownOpen` for the open signal.
    @Published private(set) var dropdownOpenedAt: Int64 = Int64(Date().timeIntervalSince1970)
    /// Whether the dropdown panel is currently open (M5 T9: the row status
    /// symbol's working spinner animates only while it is). Tracked via the
    /// same `NSWindow` key notifications as `dropdownOpenedAt`.
    @Published private(set) var isDropdownOpen = false
    /// `visibleFrame` height (menu bar and Dock excluded) of the display
    /// the dropdown panel is actually on, captured per open like
    /// `dropdownOpenedAt` (§4.5/§8.32, M29 T1 — multi-display setups use
    /// the panel's own display, read off the panel `NSWindow` the open
    /// notification carries). Drives the dropdown list's height cap — see
    /// `AgentListView`. Seeded from the main screen so the very first
    /// render (before the first open signal lands) has a sane value.
    @Published private(set) var dropdownScreenVisibleHeight: Double =
        Double(NSScreen.main?.visibleFrame.height ?? 800)
    /// "Sort by" selection (§4.5/§8.25/§8.31, M5 T9): persisted in
    /// UserDefaults, falling back to `SortMode.defaultMode` ("Grouped")
    /// when nothing — or an unknown value, e.g. one stored by a build
    /// that still had the mode §8.31 removed — is stored.
    @Published private(set) var sortMode: SortMode
    private static let sortModeKey = "cc.shiibar.sortMode"
    /// Settings > General "Appearance" (§4.5/§8.30, M27 T5): System /
    /// Light / Dark, persisted in UserDefaults (same pattern as
    /// `sortMode`), applied as `NSApp.appearance` the moment it's picked
    /// and re-applied at launch (`start()`). The tray icon is a template
    /// image, so it keeps following the menu bar's own appearance
    /// regardless (§4.5).
    @Published private(set) var appearanceSetting: AppearanceSetting
    private static let appearanceKey = "cc.shiibar.appearance"
    /// Current `GlyphCycleSpinner` frame index of the tray's working
    /// animation (M5 T8, M24 T1). Only meaningful while
    /// `workingAnimationTimer` is running; `trayIcon` reads it on every
    /// render regardless.
    @Published private(set) var workingAnimationFrame = 0
    private var workingAnimationTimer: Timer?

    let notificationManager: NotificationManager
    private let lifecycle: DaemonLifecycleManager
    /// Not `private`: the Setup Check window (§4.5, M5 T5) also needs it to
    /// run `shiibar-cc doctor --json` via `CLIRunner`, same as `focus` /
    /// `runReconcile` below.
    let helpersDirectory: URL?
    private var dropdownOpenObserver: NSObjectProtocol?
    private var dropdownCloseObserver: NSObjectProtocol?
    private var dropdownPlacementObservers: [NSObjectProtocol] = []
    /// Enforces the dropdown panel window's height (M29 panel-height
    /// bugfix — see `DropdownPanelSizer` at the bottom of this file).
    /// Deliberately non-isolated so the `didMove` closure can call it
    /// synchronously — a main-actor hop would defer the correction past
    /// the panel's next draw.
    private let dropdownPanelSizer = DropdownPanelSizer()
    /// Drives periodic reconcile (§4.5/§8.22/§9): started once in `start()`,
    /// invalidated in `deinit`. The interval/tolerance values live in
    /// `PeriodicReconcile` (ShiibarCcCore) — the scheduler itself is
    /// AppKit-only and can't move there.
    private var periodicReconcileScheduler: NSBackgroundActivityScheduler?

    var home: String? { ProcessInfo.processInfo.environment["HOME"] }

    init(helpersDirectory: URL?) {
        self.helpersDirectory = helpersDirectory
        let notificationManager = NotificationManager()
        self.notificationManager = notificationManager
        let storedSortMode = UserDefaults.standard.string(forKey: Self.sortModeKey).flatMap(SortMode.init(rawValue:))
        self.sortMode = storedSortMode ?? SortMode.defaultMode
        let storedAppearance = UserDefaults.standard.string(forKey: Self.appearanceKey)
            .flatMap(AppearanceSetting.init(rawValue:))
        self.appearanceSetting = storedAppearance ?? AppearanceSetting.defaultSetting

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
        observeDropdownOpen()
    }

    deinit {
        if let observer = dropdownOpenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = dropdownCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        let placementObservers = dropdownPlacementObservers
        for observer in placementObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        workingAnimationTimer?.invalidate()
        periodicReconcileScheduler?.invalidate()
    }

    /// Refresh `dropdownOpenedAt` (and `isDropdownOpen`) every time the
    /// dropdown panel opens; track its close the same way.
    ///
    /// The open signal is `NSWindow.didBecomeKeyNotification`: the
    /// MenuBarExtra window-style panel becomes the key window on every
    /// open (it's an interactive panel — that's also why clicking outside
    /// closes it: it resigns key), and key status is granted anew per
    /// open, so this fires per open by AppKit window-lifecycle semantics.
    /// `onAppear` on the dropdown view is NOT reliable here: the hosted
    /// view stays alive across open/close (verified on-device — that's
    /// what froze the old render-time elapsed values on reopen), so it may
    /// fire only once at launch. NSWindow notifications are per-process;
    /// the only other window this app owns is the status item's host
    /// (class `NSStatusBarWindow`), which is filtered out — the same
    /// assumption `dismissDropdown` relies on. The close signal
    /// (`didResignKeyNotification`) is the same window's counterpart,
    /// filtered identically — that's what stops the row spinner from
    /// animating while the dropdown is closed (M5 T9).
    private func observeDropdownOpen() {
        dropdownOpenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  !window.className.contains("NSStatusBarWindow"),
                  let self else { return }
            // The panel is on screen when it becomes key, so its `screen`
            // is the display the dropdown actually opened on (M29 T1).
            let screenVisibleHeight = (window.screen?.visibleFrame.height).map(Double.init)
            Task { @MainActor in
                self.captureDropdownOpenTime(screenVisibleHeight: screenVisibleHeight)
            }
        }
        dropdownCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  !window.className.contains("NSStatusBarWindow"),
                  let self else { return }
            // Losing key status is NOT the same as closing: opening the
            // v-chip's NSMenu also resigns key while the panel stays on
            // screen (and in an LSUIElement app, key may never come back
            // after the menu closes). Treat "closed" as key-loss WHILE
            // no longer visible; a visible panel stays "open" so the row
            // spinners keep turning through menu interactions.
            let stillVisible = window.isVisible
            Task { @MainActor in
                self.isDropdownOpen = stillVisible
            }
        }
        // Panel placement and size enforcement (§4.5 "panel placement" +
        // the M29 panel-height bugfix), hooked on BOTH `didMove` and
        // `didResize` — measured on-device:
        // - Near the display's right edge the OS flips the panel to extend
        //   LEFT from the icon; the spec wants the NSMenu edge behavior
        //   instead (shift the whole panel left, right edge flush with the
        //   visible area). `didBecomeKey` is too early (on first open the
        //   panel still sits at (0,0), and a shift applied there is
        //   overwritten by the OS placement that follows); the placement
        //   itself fires `didMove`, so correcting here runs AFTER each OS
        //   move and sticks — while the panel is still occluded
        //   (pre-first-draw), so no visible jump.
        // - SwiftUI's own MenuBarExtra sizing clamps the panel height to
        //   ~1/3 of the display's visible height regardless of the
        //   content's ideal, and it reasserts that height on reopen and on
        //   content changes — sometimes WITHOUT an origin change, which is
        //   why `didResize` must be hooked too (with `didMove` alone the
        //   reassertion won on reopen/growth; with both, every scenario
        //   converges to the desired height in one correction).
        // Self-triggering is safe: our own setFrame re-fires these
        // notifications, where desired == current and the tolerance guards
        // no-op. The class-name filter is the same private-API assumption
        // family as `dismissDropdown` (measured class:
        // `_TtGC7SwiftUI18MenuBarExtraWindow…`); if a macOS version renames
        // it, no correction happens and the panel degrades to the OS
        // flip + OS height clamp.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            dropdownPlacementObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main,
                using: { [sizer = dropdownPanelSizer] notification in
                    guard let panel = notification.object as? NSWindow,
                          panel.className.contains("MenuBarExtraWindow"),
                          let icon = NSApp.windows.first(where: { $0.className.contains("NSStatusBarWindow") }),
                          let screen = panel.screen ?? icon.screen else { return }
                    let visible = screen.visibleFrame
                    let desiredX = DropdownPanelPlacement.clampedX(
                        iconMinX: Double(icon.frame.minX),
                        panelWidth: Double(panel.frame.width),
                        visibleMinX: Double(visible.minX),
                        visibleMaxX: Double(visible.maxX)
                    )
                    if abs(Double(panel.frame.minX) - desiredX) > DropdownPanelPlacement.tolerance {
                        panel.setFrameOrigin(NSPoint(x: desiredX, y: panel.frame.minY))
                    }
                    sizer.enforce(on: panel)
                }
            ))
        }
    }

    /// The whole-dropdown panel height the view wants (M29 panel-height
    /// bugfix): reported by `AgentListView` (measured natural list height,
    /// capped, plus chrome — see
    /// `AgentListHeights.dropdownPanelContentHeight`), enforced immediately
    /// and re-enforced after every OS move/resize of the panel. `nil`
    /// reports (window container / no measurement yet) are ignored.
    func setDropdownDesiredPanelHeight(_ height: Double?) {
        guard let height, height > 0 else { return }
        dropdownPanelSizer.desiredHeight = height
        if let panel = NSApp.windows.first(where: { $0.className.contains("MenuBarExtraWindow") }) {
            dropdownPanelSizer.enforce(on: panel)
        }
    }

    /// Also called from the dropdown's `onAppear` as a belt-and-braces
    /// second trigger (harmless if both fire on the same open; covers a
    /// macOS version whose panel mounts the view fresh per open — that
    /// path has no panel window at hand, so it passes no screen height
    /// and the last captured value stays).
    func captureDropdownOpenTime(screenVisibleHeight: Double? = nil) {
        dropdownOpenedAt = Int64(Date().timeIntervalSince1970)
        isDropdownOpen = true
        if let screenVisibleHeight {
            dropdownScreenVisibleHeight = screenVisibleHeight
        }
        // §4.5: re-evaluate the notification-permission warning row on every
        // open, not just at launch — a permission change made mid-session
        // (e.g. granted in System Settings after startup) must be reflected
        // without an app restart. `getNotificationSettings` is async, so the
        // row can lag by a beat right after opening; that's accepted (M25 —
        // it converges to the latest value on this open, no debouncing).
        notificationManager.refreshPermissionStatus()
    }

    func start() {
        // §4.5 (M27 T5): re-apply the persisted appearance at launch.
        applyAppearance()
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
            daemonConnected: connected,
            workingFrame: workingAnimationFrame
        )
    }

    /// Grouped dropdown rows as of `now`. `now` is a parameter (not read
    /// inside) so the caller — a `TimelineView` in `DropdownView` — controls
    /// the render clock: elapsed times are recomputed from each agent's
    /// `since` epoch on every tick, never stored as strings.
    func groups(now: Int64) -> [AgentGroup] {
        Grouping.groupedRows(agents: agents, now: now, home: home)
    }

    /// Flat "Newest session" rows as of `now`, computed live from `agents`
    /// on every render — `created_at` descending, the same per-render
    /// approach as `groups(now:)` above (§4.5/§8.31: the key is immutable,
    /// so the order is stable by construction, no freezing needed).
    func flatRows(now: Int64) -> [AgentRow] {
        Sorting.newestFirst(agents: agents).map { Grouping.makeRow(agent: $0, now: now, home: home) }
    }

    /// "Sort by" selection (§4.5, M5 T9): persist and publish. Both
    /// containers order live from `agents` on every render, so the new
    /// mode shows immediately with nothing to re-settle (§8.31).
    func setSortMode(_ mode: SortMode) {
        sortMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.sortModeKey)
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
    /// Dark pin the whole app — dropdown, Agents window, Settings, Setup
    /// Check — to aqua / darkAqua. The name strings live in
    /// `AppearanceSetting` (ShiibarCcCore) where a unit test pins them to
    /// the real `NSAppearance.Name` constants.
    private func applyAppearance() {
        if let rawName = appearanceSetting.nsAppearanceNameRawValue {
            NSApp.appearance = NSAppearance(named: NSAppearance.Name(rawName))
        } else {
            NSApp.appearance = nil
        }
    }

    // MARK: - Tray working animation (M5 T8, M24 T1)

    /// Start/stop the `GlyphCycleSpinner.tickIntervalSeconds`-tick animation
    /// timer (§9, 50ms) to match whether the rollup currently shows
    /// `working` — called whenever `agents` or `connected` changes (their
    /// `didSet`s above), since either can flip the rollup in or out of
    /// `working`. `hasUnreviewed` doesn't affect this decision (the badge
    /// overlay doesn't change which glyph is shown), so `false` is passed
    /// as a cheap placeholder.
    private func refreshWorkingAnimationTimer() {
        let rollupGlyph = Rollup.icon(
            statuses: agents.map(\.status),
            hasUnreviewed: false,
            daemonConnected: connected
        ).glyph
        let isWorking: Bool
        if case .working = rollupGlyph {
            isWorking = true
        } else {
            isWorking = false
        }

        switch (isWorking, workingAnimationTimer) {
        case (true, .none):
            advanceWorkingAnimationFrame()
            workingAnimationTimer = Timer.scheduledTimer(
                withTimeInterval: GlyphCycleSpinner.tickIntervalSeconds,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.advanceWorkingAnimationFrame()
                }
            }
        case (false, .some(let timer)):
            timer.invalidate()
            workingAnimationTimer = nil
            workingAnimationFrame = 0
        default:
            break // already in the right state (running / not running)
        }
    }

    /// Re-derive the current frame from wall-clock time (same
    /// `GlyphCycleSpinner` formula as `RowSymbolView`'s `TimelineView`)
    /// rather than incrementing a counter — a pure function of "now" needs
    /// no separate reset-to-0 handling and stays in phase with every other
    /// spinner in the process for free.
    private func advanceWorkingAnimationFrame() {
        workingAnimationFrame = GlyphCycleSpinner.frameIndex(atReferenceTime: Date().timeIntervalSinceReferenceDate)
    }

    // MARK: - Actions (§8.4: only read/jump/refresh/UX-setting verbs live here)

    func rowClicked(target: String) {
        // §4.5: a row click runs focus AND closes the dropdown. Focusing
        // iTerm2 deactivates this app, which usually makes the panel resign
        // and hide on its own — the explicit dismissal below is the
        // guarantee for when that alone doesn't close it.
        dismissDropdown()
        focus(target: target)
    }

    /// Close the MenuBarExtra window-style dropdown panel (§4.5).
    ///
    /// macOS 13 exposes no public dismissal API for this panel and no
    /// presented-state binding for MenuBarExtra (`isInserted` only controls
    /// menu bar insertion), so the panel must be closed through
    /// MenuBarExtra's OWN toggle path: synthesizing a click on the status
    /// item's button (`performClick`). Closing the panel's window directly
    /// (`window.close()`) hides it but leaves MenuBarExtra's internal
    /// open/closed state saying "open" — the next tray click is then
    /// consumed flipping that state back and appears to do nothing (seen
    /// on-device). The synthetic click keeps the internal state in sync,
    /// exactly like a user clicking the tray to close.
    ///
    /// Private-API assumptions (shared with `observeDropdownOpen`): the
    /// status item's host window class is `NSStatusBarWindow`, and its view
    /// hierarchy contains the status button (an NSButton subclass). Failure
    /// mode if a macOS version breaks either: we fall back to closing the
    /// panel window directly, which still closes the dropdown but degrades
    /// to the consumed-first-click behavior (on-device checkpoint).
    func dismissDropdown() {
        if let statusWindow = NSApp.windows.first(where: { $0.className.contains("NSStatusBarWindow") }),
           let button = firstButton(in: statusWindow.contentView) {
            button.performClick(nil)
            return
        }
        // Degraded fallback: closes the panel but desyncs MenuBarExtra's
        // toggle (next tray click gets consumed).
        for window in NSApp.windows where window.isVisible && !window.className.contains("NSStatusBarWindow") {
            window.close()
        }
    }

    private func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let found = firstButton(in: subview) { return found }
        }
        return nil
    }

    /// Raise the TCC warning row when a subprocess reported exit 3 (§4.5).
    /// The nonzero-exit os_log line is emitted centrally by CLIRunner.
    private func noteExitCode(_ exitCode: Int32) {
        if exitCode == 3 {
            tccWarning = true
        }
    }

    func focus(target: String) {
        DispatchQueue.global(qos: .userInitiated).async { [helpersDirectory] in
            let result = CLIRunner.focus(target: target, helpersDirectory: helpersDirectory)
            Task { @MainActor [weak self] in
                self?.noteExitCode(result.exitCode)
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
        DispatchQueue.global(qos: .utility).async { [helpersDirectory] in
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

/// Keeps the MenuBarExtra panel window as tall as the dropdown content
/// wants (M29 panel-height bugfix). Measured on-device: SwiftUI's own
/// MenuBarExtra sizing clamps the panel to roughly a third of the
/// display's visible height (342pt on a 1025pt visible frame) no matter
/// how tall the content's ideal is, so the M29 "grow to the display" cap
/// could never engage — while a direct window `setFrame` above that limit
/// sticks, the hosted content re-lays out to fill it (the list's
/// `maxHeight` cap keeps it bounded), and later content churn does not
/// snap it back. `desiredHeight` comes from the view's measurement
/// (`AppState.setDropdownDesiredPanelHeight`); enforcement is top-edge
/// anchored (the panel hangs from the menu bar). Not `@MainActor` on
/// purpose: called synchronously from the `didMove` notification closure
/// (main thread via `queue: .main`), where an actor hop would defer past
/// the panel's next draw. `@unchecked Sendable` is sound here: every
/// access is on the main thread by construction (`queue: .main` observers
/// and `@MainActor AppState` methods).
private final class DropdownPanelSizer: @unchecked Sendable {
    var desiredHeight: Double?

    func enforce(on panel: NSWindow) {
        guard let desired = desiredHeight,
              abs(Double(panel.frame.height) - desired) > DropdownPanelPlacement.tolerance else { return }
        let frame = panel.frame
        panel.setFrame(
            NSRect(
                x: frame.minX,
                y: frame.maxY - CGFloat(desired),
                width: frame.width,
                height: CGFloat(desired)
            ),
            display: true
        )
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
