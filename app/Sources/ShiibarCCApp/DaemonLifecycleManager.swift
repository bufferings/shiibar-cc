// Daemon lifecycle (DESIGN.md §4.5 "daemon のライフサイクル管理"): on launch,
// try to attach to an already-running daemon; if that fails, spawn the
// bundled `shiibar-ccd` and keep retrying with backoff. On quit, send
// `{"cmd":"shutdown"}` so the daemon exits with the app (§8.8: daemon
// lifecycle is subordinate to the menu bar app, never launchd-resident).

import Foundation
import ShiibarCCCore

@MainActor
final class DaemonLifecycleManager {
    private let socketPath: String
    private let helpersDirectory: URL?
    private var connection: DaemonConnection?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var hasEverConnected = false
    private var daemonProcess: Process?

    /// Called (main actor) whenever the daemon connection's coarse state
    /// changes — drives the "disconnected" warning row + tray dimming
    /// (§4.5).
    var onConnectedChanged: ((Bool) -> Void)?
    /// Called (main actor) for every decoded subscribe event.
    var onEvent: ((SubscribeEvent) -> Void)?

    init(socketPath: String, helpersDirectory: URL?) {
        self.socketPath = socketPath
        self.helpersDirectory = helpersDirectory
    }

    func start() {
        attemptConnect()
    }

    private func attemptConnect() {
        reconnectWorkItem?.cancel()
        let conn = DaemonConnection(socketPath: socketPath)
        connection = conn
        conn.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }
        conn.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.onEvent?(event)
            }
        }
        conn.connect()
    }

    private func handleStateChange(_ state: DaemonConnectionState) {
        switch state {
        case .ready:
            reconnectAttempt = 0
            hasEverConnected = true
            onConnectedChanged?(true)
        case .failed, .cancelled:
            onConnectedChanged?(false)
            // First-ever failure to attach: nothing is listening yet, so
            // spawn the bundled daemon (dev builds without a helpers
            // directory rely on a manually-started `shiibar-ccd
            // --foreground`, per the M4 task brief).
            if !hasEverConnected, reconnectAttempt == 0, daemonProcess == nil {
                spawnBundledDaemonIfPossible()
            }
            scheduleReconnect()
        case .connecting:
            break
        }
    }

    private func scheduleReconnect() {
        let delay = ReconnectBackoff.delay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptConnect()
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func spawnBundledDaemonIfPossible() {
        guard let helpersDirectory else { return }
        let path = HelperPathResolver.resolvedPath(for: .shiibarCcd, helpersDirectory: helpersDirectory)
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = []
        do {
            try process.run()
            daemonProcess = process
        } catch {
            // Nothing more we can do here beyond keep retrying the
            // connection with backoff; the disconnected warning row
            // surfaces this to the user (§4.5).
        }
    }

    /// Send `{"cmd":"shutdown"}` and tear down (app Quit, §4.5).
    func shutdown(completion: @escaping () -> Void) {
        reconnectWorkItem?.cancel()
        let shutdownConnection = DaemonConnection(socketPath: socketPath)
        shutdownConnection.sendOneShot("{\"cmd\":\"shutdown\"}") {
            completion()
        }
    }
}
