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
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var connected = false
    /// Any of focus / reconcile / focused returned exit 3 (§4.5: not
    /// focus-only — a reconcile silenced by a missing Automation permission
    /// would silently lose the whole backstop).
    @Published var tccWarning = false
    @Published var muted: Bool
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

    let notificationManager: NotificationManager
    private let lifecycle: DaemonLifecycleManager
    private let helpersDirectory: URL?
    private var dropdownOpenObserver: NSObjectProtocol?

    var home: String? { ProcessInfo.processInfo.environment["HOME"] }

    init(helpersDirectory: URL?) {
        self.helpersDirectory = helpersDirectory
        let notificationManager = NotificationManager(helpersDirectoryProvider: { helpersDirectory })
        self.notificationManager = notificationManager
        self.muted = notificationManager.isMuted

        let root = StateDirectory.resolveRoot() ?? (NSHomeDirectory() + "/.local/state/shiibar-cc")
        self.lifecycle = DaemonLifecycleManager(
            socketPath: StateDirectory.socketPath(root: root),
            daemonLogPath: StateDirectory.daemonLogPath(root: root),
            helpersDirectory: helpersDirectory
        )

        notificationManager.currentlyUnreviewedTargets = { [weak self] in
            Set((self?.agents ?? []).filter(\.unreviewed).map(\.target))
        }
        notificationManager.onFocusRequested = { [weak self] target in
            self?.focus(target: target)
        }
        notificationManager.onTCCError = { [weak self] in
            self?.tccWarning = true
        }
        observeDropdownOpen()
    }

    deinit {
        if let observer = dropdownOpenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Refresh `dropdownOpenedAt` every time the dropdown panel opens.
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
    /// assumption `dismissDropdown` relies on.
    private func observeDropdownOpen() {
        dropdownOpenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  !window.className.contains("NSStatusBarWindow"),
                  let self else { return }
            Task { @MainActor in
                self.captureDropdownOpenTime()
            }
        }
    }

    /// Also called from the dropdown's `onAppear` as a belt-and-braces
    /// second trigger (harmless if both fire on the same open; covers a
    /// macOS version whose panel mounts the view fresh per open).
    func captureDropdownOpenTime() {
        dropdownOpenedAt = Int64(Date().timeIntervalSince1970)
    }

    func start() {
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
    }

    func handle(event: SubscribeEvent) {
        switch event {
        case .snapshot(let snapshotAgents):
            agents = snapshotAgents
            notificationManager.observe(agents: agents)
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

    var trayIcon: TrayIconState {
        Rollup.icon(
            statuses: agents.map(\.status),
            hasUnreviewed: agents.contains { $0.unreviewed },
            daemonConnected: connected
        )
    }

    /// Grouped dropdown rows as of `now`. `now` is a parameter (not read
    /// inside) so the caller — a `TimelineView` in `DropdownView` — controls
    /// the render clock: elapsed times are recomputed from each agent's
    /// `since` epoch on every tick, never stored as strings.
    func groups(now: Int64) -> [AgentGroup] {
        Grouping.groupedRows(agents: agents, now: now, home: home)
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
    private func dismissDropdown() {
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

    /// Reconcile via the CLI (§3.5/§4.5). Reached from all three trigger
    /// paths — startup, daemon reconnect (`onConnectedChanged`), and the ⌄
    /// menu's Rescan — so a permission failure surfaces even before the
    /// user ever clicks anything.
    ///
    /// `showFeedback`: only the manual ⌄-menu Rescan passes `true` — §4.5
    /// scopes the transient feedback to the manual trigger, so the
    /// automatic startup/reconnect calls stay silent.
    ///
    /// Overlapping-run guard: a second manual Rescan while one is already
    /// running is ignored (simpler than cancelling the in-flight subprocess
    /// or restarting its feedback timer) — reconcile is idempotent, so a
    /// duplicate tap during an in-flight run loses nothing but an extra
    /// subprocess launch; the in-flight run still resyncs state and reports
    /// its own feedback when it finishes.
    func runReconcile(showFeedback: Bool = false) {
        if showFeedback {
            guard rescanFeedback != .running else { return }
            showRescanFeedback(.running)
        }
        DispatchQueue.global(qos: .utility).async { [helpersDirectory] in
            let result = CLIRunner.reconcile(helpersDirectory: helpersDirectory)
            Task { @MainActor [weak self] in
                self?.noteExitCode(result.exitCode)
                guard showFeedback else { return }
                if let feedback = RescanFeedback.forFinishedExitCode(result.exitCode) {
                    self?.showRescanFeedback(feedback)
                } else {
                    // Exit 3 (TCC): the warning row is already handling it
                    // (via `noteExitCode` above) — clear "Rescanning…"
                    // immediately rather than flashing transient text too.
                    self?.rescanFeedback = nil
                }
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

    /// ⌄ menu "Mute Sound" toggle (UserDefaults, §4.5/§8.14).
    func toggleMute() {
        muted.toggle()
        notificationManager.isMuted = muted
    }

    /// ⌄ menu "Start at Login" checkmark (§4.5, M5 T3): read live, never
    /// cached — `SMAppService.mainApp.status` is the sole source of truth
    /// so the checkmark can't drift from System Settings' own Login Items
    /// UI. `DropdownView` re-reads this every render; the dropdown reopen
    /// refresh (`dropdownOpenedAt`, above) is what makes that render happen
    /// on each open, the same mechanism the rest of the dropdown's per-open
    /// values rely on.
    var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// ⌄ menu "Start at Login" toggle (§4.5, M5 T3): register/unregister
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
