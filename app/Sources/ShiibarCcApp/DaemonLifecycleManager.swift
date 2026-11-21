// Daemon lifecycle management (DESIGN.md §4.5): on launch,
// try to attach to an already-running daemon; if that fails, spawn the
// bundled `shiibar-ccd` and keep retrying with backoff. On quit, send
// `{"cmd":"shutdown"}` so the daemon exits with the app (§8.8: daemon
// lifecycle is subordinate to the menu bar app, never launchd-resident).
// Before each attach, `DaemonVersionGate` (ShiibarCcCore) replaces a daemon
// whose version differs from the bundle's with the bundled one, sending at
// most one `shutdown` per launch and never to one this app spawned (§4.5,
// §8.66). A replacement whose wait timed out is completed by the gate at a
// later attach that finds the old daemon stopped.

import Foundation
import ShiibarCcCore

@MainActor
final class DaemonLifecycleManager {
    private let socketPath: String
    /// `<state dir>/shiibar-ccd.log` — where an app-spawned daemon's stderr
    /// goes (§4.2). Derived from the same resolved state dir as the socket,
    /// so it honors `SHIIBAR_CC_STATE_DIR` like everything else.
    private let daemonLogPath: String
    private let helpersDirectory: URL?
    private var connection: DaemonConnection?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var hasEverConnected = false
    private var daemonProcess: Process?
    private var gate: DaemonVersionGate!
    private var isShuttingDown = false

    /// Called (main actor) whenever the daemon connection's coarse state
    /// changes — drives the "disconnected" warning row + tray dimming
    /// (§4.5).
    var onConnectedChanged: ((Bool) -> Void)?
    /// Called (main actor) for every decoded subscribe event.
    var onEvent: ((SubscribeEvent) -> Void)?

    /// `bundleVersion`: the app bundle's `CFBundleShortVersionString`, nil
    /// when the app runs outside a bundle (§4.5: then no version check).
    init(socketPath: String, daemonLogPath: String, helpersDirectory: URL?, bundleVersion: String?) {
        self.socketPath = socketPath
        self.daemonLogPath = daemonLogPath
        self.helpersDirectory = helpersDirectory
        let socketPath = socketPath
        gate = DaemonVersionGate(environment: .init(
            bundleVersion: bundleVersion,
            hasBundledDaemon: { [weak self] in self?.bundledDaemonPath() != nil },
            fetchDaemonVersion: {
                await Self.offMain { DaemonSocketProbe.fetchVersion(socketPath: socketPath) }
            },
            sendShutdown: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    // The one-shot send keeps its own reference to the
                    // underlying connection, so this object only has to
                    // live until `sendOneShot` returns (same as `shutdown`).
                    let shutdownConnection = DaemonConnection(socketPath: socketPath)
                    shutdownConnection.sendOneShot(Self.shutdownRequest) {
                        continuation.resume()
                    }
                }
            },
            isDaemonStopped: {
                await Self.offMain { DaemonSocketProbe.isStopped(socketPath: socketPath) }
            },
            spawnBundledDaemon: { [weak self] in self?.spawnBundledDaemonIfPossible() },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        ))
    }

    private static let shutdownRequest = "{\"cmd\":\"shutdown\"}"

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    func start() {
        attemptConnect()
    }

    private func attemptConnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        // The daemon this app spawned is still running, so the one that
        // answers is ours: never replaced (§4.5).
        let daemonSpawnedByApp = daemonProcess?.isRunning == true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.gate.checkBeforeAttach(daemonSpawnedByApp: daemonSpawnedByApp)
            guard !self.isShuttingDown else { return }
            switch outcome {
            case .attach, .replaced:
                self.openSubscribeConnection()
            case .oldDaemonStillRunning:
                // §4.5: spawn nothing, stay disconnected (the warning row
                // shows), and keep reconnecting.
                self.onConnectedChanged?(false)
                self.scheduleReconnect()
            }
        }
    }

    private func openSubscribeConnection() {
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
            // --foreground`, per the M4 task brief). The spawn after a
            // version replacement runs from `DaemonVersionGate` instead,
            // at any attach (§4.5).
            if !hasEverConnected, reconnectAttempt == 0, daemonProcess == nil {
                spawnBundledDaemonIfPossible()
            }
            scheduleReconnect()
        case .connecting:
            break
        }
    }

    private func scheduleReconnect() {
        guard !isShuttingDown else { return }
        let delay = ReconnectBackoff.delay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptConnect()
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// The bundled `shiibar-ccd`, nil when the app has no helpers directory
    /// or the binary is missing (an app run outside a bundle).
    private func bundledDaemonPath() -> String? {
        guard let helpersDirectory else { return nil }
        let path = HelperPathResolver.resolvedPath(for: .shiibarCcd, helpersDirectory: helpersDirectory)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Spawns the bundled daemon: on the first failure to attach, and after
    /// a daemon of a different version stopped (§4.5).
    private func spawnBundledDaemonIfPossible() {
        guard let path = bundledDaemonPath() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = []
        // Same augmented PATH as every app-run subprocess (see
        // SubprocessEnvironment): the daemon itself doesn't spawn
        // PATH-resolved tools today, but inheriting launchd's minimal PATH
        // is exactly the trap that silently degraded app-run reconciles —
        // don't leave the same landmine armed here.
        process.environment = SubprocessEnvironment.withAugmentedPath()
        // §4.2: an app-spawned daemon must not be log-less — redirect its
        // stderr (the daemon's only log stream) to <state dir>/
        // shiibar-ccd.log, overwriting the previous run's file. The state
        // dir may not exist yet on a first run (the daemon itself creates
        // it at bind time, but the log file must exist before the daemon
        // runs), so create it here too. If any of this fails, still spawn —
        // a log-less daemon beats no daemon.
        let logDirectory = (daemonLogPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        FileManager.default.createFile(atPath: daemonLogPath, contents: nil)
        if let logHandle = FileHandle(forWritingAtPath: daemonLogPath) {
            process.standardError = logHandle
        }
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
        isShuttingDown = true
        reconnectWorkItem?.cancel()
        let shutdownConnection = DaemonConnection(socketPath: socketPath)
        shutdownConnection.sendOneShot(Self.shutdownRequest) {
            completion()
        }
    }
}
