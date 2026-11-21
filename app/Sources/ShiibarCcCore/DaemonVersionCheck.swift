// Not attaching to a daemon whose version differs from the app bundle's
// (DESIGN.md §4.5 "daemon lifecycle management", §4.2 "protocol contract",
// §8.66): when the app attaches to a daemon, it sends `info` and compares
// `version` with the bundle's `CFBundleShortVersionString` (a trailing
// `-dev` is ignored). When they differ, the app sends `shutdown` to that
// daemon, waits for it to stop (§9: 3 seconds from sending `shutdown`), and
// then spawns the bundled `shiibar-ccd`. If it does not stop in time, the
// app spawns nothing and stays disconnected (the reconnect continues); the
// replacement then stays pending: at each later attach, a daemon that has
// stopped by then is replaced by the bundled one (spawned once), and a
// daemon that answers is attached to without a second `shutdown`.
//
// The `shutdown` is sent at most once per app launch and never to a
// daemon this app spawned, so a bundled daemon whose version differs from
// the bundle's does not cause a stop / start loop (§8.66). Without a known
// bundle version or a bundled daemon (an app run outside a bundle), the app
// attaches without comparing.

import Foundation

public enum DaemonVersionCheck {
    /// §9: how long the app waits, from sending `shutdown`, for a daemon of
    /// a different version to stop before giving up on spawning.
    public static let stopWaitSeconds: Double = 3
    /// How often the stop condition is re-checked while waiting.
    public static let stopPollSeconds: Double = 0.1

    /// The version with a trailing `-dev` removed (§4.5: dev builds name
    /// themselves `X.Y.Z-dev`, §8.28; the comparison ignores the suffix).
    public static func normalized(_ version: String) -> String {
        version.hasSuffix("-dev") ? String(version.dropLast(4)) : version
    }

    /// Whether the two versions differ once a trailing `-dev` is ignored.
    public static func versionsDiffer(bundleVersion: String, daemonVersion: String) -> Bool {
        normalized(bundleVersion) != normalized(daemonVersion)
    }

    /// Whether the app should look at the daemon's version at all before
    /// attaching (§4.5). No: the replacement already ran in this launch,
    /// the responding daemon is the one this app spawned, the bundle
    /// version is unknown, or there is no bundled daemon to replace it
    /// with.
    public static func shouldCheck(
        bundleVersion: String?,
        hasBundledDaemon: Bool,
        alreadyReplaced: Bool,
        daemonSpawnedByApp: Bool
    ) -> Bool {
        guard let bundleVersion, !normalized(bundleVersion).isEmpty else { return false }
        return hasBundledDaemon && !alreadyReplaced && !daemonSpawnedByApp
    }

    public enum Decision: Equatable, Sendable {
        case attach
        case replace
    }

    /// The whole decision (§4.5). `daemonVersion` is the `version` of the
    /// daemon's `info` response, nil when `info` failed (the app attaches:
    /// a daemon that answers is not stopped only because its information
    /// could not be read).
    public static func decide(
        bundleVersion: String?,
        hasBundledDaemon: Bool,
        alreadyReplaced: Bool,
        daemonSpawnedByApp: Bool,
        daemonVersion: String?
    ) -> Decision {
        guard shouldCheck(
            bundleVersion: bundleVersion,
            hasBundledDaemon: hasBundledDaemon,
            alreadyReplaced: alreadyReplaced,
            daemonSpawnedByApp: daemonSpawnedByApp
        ), let bundleVersion, let daemonVersion else { return .attach }
        return versionsDiffer(bundleVersion: bundleVersion, daemonVersion: daemonVersion) ? .replace : .attach
    }

    /// The `version` of an `info` response line
    /// (`{"ok":true,"version":"…",…}`, §4.2), nil when the response is not
    /// a successful `info` response.
    public static func parseInfoVersion(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true,
              let version = object["version"] as? String
        else { return nil }
        return version
    }
}

/// Runs the version check at each attach (launch and every reconnect) and,
/// when needed, the one replacement of this launch. Every outward action is
/// injected so the sequence is testable without a daemon.
@MainActor
public final class DaemonVersionGate {
    public struct Environment {
        /// The bundle's `CFBundleShortVersionString`, nil when unknown.
        public var bundleVersion: String?
        /// Whether the bundled `shiibar-ccd` exists.
        public var hasBundledDaemon: () -> Bool
        /// Sends `info` to the daemon; its `version`, or nil when `info`
        /// failed (including when no daemon answered).
        public var fetchDaemonVersion: () async -> String?
        /// Sends `shutdown` to the daemon.
        public var sendShutdown: () async -> Void
        /// Whether the daemon has stopped: the socket file is gone, or a
        /// connection to it is refused (§4.5).
        public var isDaemonStopped: () async -> Bool
        /// Spawns the bundled daemon.
        public var spawnBundledDaemon: () -> Void
        /// Monotonic time in seconds.
        public var now: () -> Double
        public var sleep: (Double) async -> Void

        public init(
            bundleVersion: String?,
            hasBundledDaemon: @escaping () -> Bool,
            fetchDaemonVersion: @escaping () async -> String?,
            sendShutdown: @escaping () async -> Void,
            isDaemonStopped: @escaping () async -> Bool,
            spawnBundledDaemon: @escaping () -> Void,
            now: @escaping () -> Double,
            sleep: @escaping (Double) async -> Void
        ) {
            self.bundleVersion = bundleVersion
            self.hasBundledDaemon = hasBundledDaemon
            self.fetchDaemonVersion = fetchDaemonVersion
            self.sendShutdown = sendShutdown
            self.isDaemonStopped = isDaemonStopped
            self.spawnBundledDaemon = spawnBundledDaemon
            self.now = now
            self.sleep = sleep
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Attach to whatever answers (or connect normally when nothing
        /// does).
        case attach
        /// The old daemon stopped and the bundled one was spawned; connect
        /// to it.
        case replaced
        /// The old daemon did not stop within §9's time: nothing was
        /// spawned; stay disconnected and keep reconnecting. The
        /// replacement stays pending for the later attaches.
        case oldDaemonStillRunning
    }

    private let environment: Environment
    /// The replacement runs at most once per app launch (§4.5): set when
    /// its `shutdown` is sent, so no second `shutdown` is ever sent.
    public private(set) var hasReplaced = false
    /// The replacement's wait timed out and the bundled daemon has not been
    /// spawned yet. Cleared by the spawn.
    public private(set) var isReplacementPending = false

    public init(environment: Environment) {
        self.environment = environment
    }

    /// Called before every attach. `daemonSpawnedByApp`: the daemon this
    /// app spawned is still running, so the one that answers is ours and
    /// is never replaced (§4.5).
    public func checkBeforeAttach(daemonSpawnedByApp: Bool) async -> Outcome {
        if isReplacementPending, !daemonSpawnedByApp {
            return await completePendingReplacement()
        }
        guard DaemonVersionCheck.shouldCheck(
            bundleVersion: environment.bundleVersion,
            hasBundledDaemon: environment.hasBundledDaemon(),
            alreadyReplaced: hasReplaced,
            daemonSpawnedByApp: daemonSpawnedByApp
        ) else { return .attach }

        let daemonVersion = await environment.fetchDaemonVersion()
        // Re-check the once-per-launch flag after the suspension point.
        let decision = DaemonVersionCheck.decide(
            bundleVersion: environment.bundleVersion,
            hasBundledDaemon: true,
            alreadyReplaced: hasReplaced,
            daemonSpawnedByApp: daemonSpawnedByApp,
            daemonVersion: daemonVersion
        )
        guard decision == .replace else { return .attach }

        hasReplaced = true
        // §9: the wait counts from sending `shutdown`, not from when the
        // send call returns (it can return only at its own timeout).
        let deadline = environment.now() + DaemonVersionCheck.stopWaitSeconds
        await environment.sendShutdown()
        while true {
            if await environment.isDaemonStopped() {
                environment.spawnBundledDaemon()
                return .replaced
            }
            let remaining = deadline - environment.now()
            if remaining <= 0 {
                isReplacementPending = true
                return .oldDaemonStillRunning
            }
            await environment.sleep(min(DaemonVersionCheck.stopPollSeconds, remaining))
        }
    }

    /// A later attach while the replacement is pending: the old daemon has
    /// stopped (socket file gone or connection refused), so the bundled
    /// daemon is spawned and the replacement is complete; otherwise a
    /// daemon still accepts connections and the app attaches to it without
    /// a second `shutdown`, the replacement staying pending so a stop later
    /// still spawns the bundled daemon. Nothing is spawned while a daemon
    /// may still be running.
    private func completePendingReplacement() async -> Outcome {
        guard await environment.isDaemonStopped() else { return .attach }
        // Re-check after the suspension point: another attach may have
        // completed it meanwhile.
        guard isReplacementPending else { return .attach }
        isReplacementPending = false
        environment.spawnBundledDaemon()
        return .replaced
    }
}
