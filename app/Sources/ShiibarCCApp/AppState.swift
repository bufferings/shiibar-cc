// Central app state (DESIGN.md §4.5): owns the agent table (kept in sync via
// the daemon subscribe stream), drives reconcile at startup/reconnect,
// dispatches CLI subprocess calls for focus/back/rescan, and wires
// `agent_removed` into notification cleanup.

import AppKit
import Combine
import Foundation
import ShiibarCCCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var connected = false
    @Published var focusTCCWarning = false
    @Published var muted: Bool

    let notificationManager: NotificationManager
    private let lifecycle: DaemonLifecycleManager
    private let helpersDirectory: URL?

    var home: String? { ProcessInfo.processInfo.environment["HOME"] }

    init(helpersDirectory: URL?) {
        self.helpersDirectory = helpersDirectory
        let notificationManager = NotificationManager(helpersDirectoryProvider: { helpersDirectory })
        self.notificationManager = notificationManager
        self.muted = notificationManager.isMuted

        let root = StateDirectory.resolveRoot() ?? (NSHomeDirectory() + "/.local/state/shiibar-cc")
        let socketPath = StateDirectory.socketPath(root: root)
        self.lifecycle = DaemonLifecycleManager(socketPath: socketPath, helpersDirectory: helpersDirectory)

        notificationManager.currentlyUnreviewedTargets = { [weak self] in
            Set((self?.agents ?? []).filter(\.unreviewed).map(\.target))
        }
        notificationManager.onFocusRequested = { [weak self] target in
            self?.focus(target: target)
        }
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

    var groups: [AgentGroup] {
        Grouping.groupedRows(agents: agents, now: Int64(Date().timeIntervalSince1970), home: home)
    }

    // MARK: - Actions (§8.4: only read/jump/refresh/UX-setting verbs live here)

    func rowClicked(target: String) {
        focus(target: target)
    }

    func focus(target: String) {
        DispatchQueue.global(qos: .userInitiated).async { [helpersDirectory] in
            let result = CLIRunner.focus(target: target, helpersDirectory: helpersDirectory)
            Task { @MainActor [weak self] in
                if result.exitCode == 3 {
                    self?.focusTCCWarning = true
                }
            }
        }
    }

    /// ⌄ menu "Back" (`focus -`, §4.5/§8.4).
    func focusBack() {
        DispatchQueue.global(qos: .userInitiated).async { [helpersDirectory] in
            _ = CLIRunner.focusBack(helpersDirectory: helpersDirectory)
        }
    }

    /// ⌄ menu "Rescan" (manual reconcile, §3.5/§4.5).
    func runReconcile() {
        DispatchQueue.global(qos: .utility).async { [helpersDirectory] in
            _ = CLIRunner.reconcile(helpersDirectory: helpersDirectory)
        }
    }

    /// ⌄ menu "Mute Sound" toggle (UserDefaults, §4.5/§8.14).
    func toggleMute() {
        muted.toggle()
        notificationManager.isMuted = muted
    }

    /// ⌄ menu "Quit": stop the daemon, then the app (§4.5/§8.8).
    func quit() {
        lifecycle.shutdown {
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
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
