import XCTest
@testable import ShiibarCcCore

/// DESIGN.md §4.5 "daemon lifecycle management": the app does not attach to
/// a daemon whose version differs from the bundle's.
final class DaemonVersionCheckTests: XCTestCase {
    func testVersionComparisonIgnoresATrailingDevSuffix() {
        let cases: [(bundle: String, daemon: String, differ: Bool)] = [
            ("0.9.1", "0.9.1", false),
            ("0.9.1-dev", "0.9.1", false),
            ("0.9.1", "0.9.1-dev", false),
            ("0.9.1-dev", "0.9.1-dev", false),
            ("0.9.1", "0.9.0", true),
            ("0.9.1-dev", "0.9.0", true),
            ("1.0.0", "0.9.1", true),
        ]
        for c in cases {
            XCTAssertEqual(
                DaemonVersionCheck.versionsDiffer(bundleVersion: c.bundle, daemonVersion: c.daemon), c.differ,
                "\(c.bundle) vs \(c.daemon)"
            )
        }
    }

    func testDecisionTable() {
        struct Row {
            let name: String
            let bundle: String?
            let hasBundledDaemon: Bool
            let alreadyReplaced: Bool
            let spawnedByApp: Bool
            let daemon: String?
            let expected: DaemonVersionCheck.Decision
        }
        let rows: [Row] = [
            Row(name: "same version attaches", bundle: "0.9.1", hasBundledDaemon: true, alreadyReplaced: false, spawnedByApp: false, daemon: "0.9.1", expected: .attach),
            Row(name: "only -dev differs attaches", bundle: "0.9.1-dev", hasBundledDaemon: true, alreadyReplaced: false, spawnedByApp: false, daemon: "0.9.1", expected: .attach),
            Row(name: "different version replaces", bundle: "0.9.1", hasBundledDaemon: true, alreadyReplaced: false, spawnedByApp: false, daemon: "0.9.0", expected: .replace),
            Row(name: "failed info attaches", bundle: "0.9.1", hasBundledDaemon: true, alreadyReplaced: false, spawnedByApp: false, daemon: nil, expected: .attach),
            Row(name: "second replacement in one launch is not run", bundle: "0.9.1", hasBundledDaemon: true, alreadyReplaced: true, spawnedByApp: false, daemon: "0.9.0", expected: .attach),
            Row(name: "daemon spawned by this app is not replaced", bundle: "0.9.1", hasBundledDaemon: true, alreadyReplaced: false, spawnedByApp: true, daemon: "0.9.0", expected: .attach),
            Row(name: "unknown bundle version attaches", bundle: nil, hasBundledDaemon: true, alreadyReplaced: false, spawnedByApp: false, daemon: "0.9.0", expected: .attach),
            Row(name: "empty bundle version attaches", bundle: "", hasBundledDaemon: true, alreadyReplaced: false, spawnedByApp: false, daemon: "0.9.0", expected: .attach),
            Row(name: "no bundled daemon attaches", bundle: "0.9.1", hasBundledDaemon: false, alreadyReplaced: false, spawnedByApp: false, daemon: "0.9.0", expected: .attach),
        ]
        for row in rows {
            XCTAssertEqual(
                DaemonVersionCheck.decide(
                    bundleVersion: row.bundle,
                    hasBundledDaemon: row.hasBundledDaemon,
                    alreadyReplaced: row.alreadyReplaced,
                    daemonSpawnedByApp: row.spawnedByApp,
                    daemonVersion: row.daemon
                ),
                row.expected,
                row.name
            )
        }
    }

    func testParseInfoVersionReadsASuccessfulInfoResponseOnly() {
        XCTAssertEqual(
            DaemonVersionCheck.parseInfoVersion(Data(#"{"ok":true,"version":"0.9.1","started_at":1,"last_report_at":null}"#.utf8)),
            "0.9.1"
        )
        XCTAssertNil(DaemonVersionCheck.parseInfoVersion(Data(#"{"ok":false,"error":"invalid request"}"#.utf8)))
        XCTAssertNil(DaemonVersionCheck.parseInfoVersion(Data(#"{"ok":true}"#.utf8)))
        XCTAssertNil(DaemonVersionCheck.parseInfoVersion(Data("not json".utf8)))
    }

    func testStopWaitIsThreeSeconds() {
        // §9: the wait for a daemon of a different version to stop.
        XCTAssertEqual(DaemonVersionCheck.stopWaitSeconds, 3)
    }
}

/// The attach-time sequence: `info`, `shutdown`, waiting for the stop, and
/// the spawn, with every outward action replaced by a spy and time by a fake
/// clock that `sleep` advances.
@MainActor
final class DaemonVersionGateTests: XCTestCase {
    private final class Spy {
        var bundleVersion: String? = "0.9.1"
        var hasBundledDaemon = true
        /// What the running daemon answers to `info` (nil: `info` fails).
        var daemonVersion: String? = "0.9.0"
        /// The fake clock's time at which the old daemon is seen stopped
        /// (nil: never).
        var stopsAt: Double? = 0
        var now: Double = 0
        /// How long the `shutdown` send call takes to return on the fake
        /// clock.
        var shutdownCallTakes: Double = 0
        var calls: [String] = []
        var sleeps: [Double] = []

        func environment() -> DaemonVersionGate.Environment {
            .init(
                bundleVersion: bundleVersion,
                hasBundledDaemon: { self.hasBundledDaemon },
                fetchDaemonVersion: {
                    self.calls.append("info")
                    return self.daemonVersion
                },
                sendShutdown: {
                    self.calls.append("shutdown")
                    self.now += self.shutdownCallTakes
                },
                isDaemonStopped: {
                    guard let stopsAt = self.stopsAt else { return false }
                    return self.now >= stopsAt
                },
                spawnBundledDaemon: {
                    self.calls.append("spawn")
                    // The spawned daemon answers with the bundled daemon's
                    // version, which may still differ from the bundle's.
                    self.daemonVersion = "0.9.0"
                },
                now: { self.now },
                sleep: { seconds in
                    self.sleeps.append(seconds)
                    self.now += seconds
                }
            )
        }
    }

    func testSameVersionAttachesWithoutShutdown() async {
        let spy = Spy()
        spy.daemonVersion = "0.9.1"
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .attach)
        XCTAssertEqual(spy.calls, ["info"])
    }

    func testVersionsDifferingOnlyByDevSuffixAttach() async {
        let spy = Spy()
        spy.bundleVersion = "0.9.1-dev"
        spy.daemonVersion = "0.9.1"
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .attach)
        XCTAssertEqual(spy.calls, ["info"])
    }

    func testDifferentVersionSendsShutdownAndSpawnsOnceTheSocketFileIsGoneOrRefused() async {
        let spy = Spy()
        spy.stopsAt = 0.25
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(spy.calls, ["info", "shutdown", "spawn"])
        XCTAssertGreaterThanOrEqual(spy.now, 0.25)
        XCTAssertTrue(gate.hasReplaced)
    }

    func testDaemonAlreadyStoppedRightAfterShutdownSpawnsWithoutWaiting() async {
        let spy = Spy()
        spy.stopsAt = 0
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(spy.calls, ["info", "shutdown", "spawn"])
        XCTAssertEqual(spy.sleeps, [])
    }

    func testDaemonNotStoppingWithinThreeSecondsSpawnsNothing() async {
        let spy = Spy()
        spy.stopsAt = nil
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .oldDaemonStillRunning)
        XCTAssertEqual(spy.calls, ["info", "shutdown"])
        XCTAssertEqual(spy.now, DaemonVersionCheck.stopWaitSeconds, accuracy: 1e-9)
    }

    func testDaemonStoppingExactlyAtTheDeadlineStillSpawns() async {
        let spy = Spy()
        spy.stopsAt = 3
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        // The stop is checked before giving up at the deadline.
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(spy.calls, ["info", "shutdown", "spawn"])
    }

    func testFailedInfoAttaches() async {
        let spy = Spy()
        spy.daemonVersion = nil
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .attach)
        XCTAssertEqual(spy.calls, ["info"])
        XCTAssertFalse(gate.hasReplaced)
    }

    func testDaemonSpawnedAfterTheReplacementAttachesEvenWithADifferentVersion() async {
        let spy = Spy()
        let gate = DaemonVersionGate(environment: spy.environment())
        _ = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        spy.calls = []
        // The spawned daemon answers "0.9.0" (differs from "0.9.1").
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: true)
        XCTAssertEqual(outcome, .attach)
        XCTAssertEqual(spy.calls, [])
    }

    func testReplacementRunsAtMostOncePerLaunchIncludingAtReconnect() async {
        let spy = Spy()
        let gate = DaemonVersionGate(environment: spy.environment())
        _ = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        spy.calls = []
        // A reconnect later finds a daemon of a different version that this
        // app did not spawn (e.g. one started by another app of another
        // version on the same state dir): it attaches.
        spy.daemonVersion = "0.8.0"
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .attach)
        XCTAssertEqual(spy.calls, [])
    }

    func testReplacementThatTimedOutSendsNoSecondShutdownWhileADaemonAnswers() async {
        let spy = Spy()
        spy.stopsAt = nil
        let gate = DaemonVersionGate(environment: spy.environment())
        _ = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertTrue(gate.isReplacementPending)
        spy.calls = []
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .attach, "attach to the daemon that answers")
        XCTAssertEqual(spy.calls, [], "no info, no second shutdown, no spawn")
        XCTAssertTrue(gate.isReplacementPending, "a stop later still spawns the bundled daemon")
    }

    /// The old daemon stops later than §9's wait: a later attach finds it
    /// stopped and spawns the bundled daemon, exactly once.
    func testReplacementThatTimedOutSpawnsOnceTheOldDaemonHasStoppedAtALaterAttach() async {
        let spy = Spy()
        spy.stopsAt = nil
        let gate = DaemonVersionGate(environment: spy.environment())
        let first = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(first, .oldDaemonStillRunning)
        XCTAssertEqual(spy.calls, ["info", "shutdown"])

        spy.calls = []
        spy.stopsAt = spy.now + 10
        spy.now += 1
        let stillRunning = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(stillRunning, .attach)
        XCTAssertEqual(spy.calls, [], "never spawn while the old daemon may still be running")

        spy.now += 10
        let stopped = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(stopped, .replaced)
        XCTAssertEqual(spy.calls, ["spawn"])
        XCTAssertFalse(gate.isReplacementPending)

        // Later attaches: the spawned daemon, or nothing at all, spawn no
        // second daemon from the gate.
        spy.calls = []
        let ours = await gate.checkBeforeAttach(daemonSpawnedByApp: true)
        XCTAssertEqual(ours, .attach)
        let afterwards = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(afterwards, .attach)
        XCTAssertEqual(spy.calls, [])
    }

    /// §9: the wait counts from sending `shutdown`; a send call that
    /// returns late does not extend it.
    func testStopWaitCountsFromSendingShutdown() async {
        let spy = Spy()
        spy.stopsAt = nil
        spy.shutdownCallTakes = 1.5
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .oldDaemonStillRunning)
        XCTAssertEqual(spy.now, DaemonVersionCheck.stopWaitSeconds, accuracy: 1e-9)

        let late = Spy()
        late.stopsAt = 3.5
        late.shutdownCallTakes = 1.5
        let lateGate = DaemonVersionGate(environment: late.environment())
        let lateOutcome = await lateGate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(lateOutcome, .oldDaemonStillRunning, "a stop 3.5 s after sending is past the wait")
        XCTAssertEqual(late.calls, ["info", "shutdown"])
    }

    func testDaemonSpawnedByThisAppIsNeverReplaced() async {
        let spy = Spy()
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: true)
        XCTAssertEqual(outcome, .attach)
        XCTAssertEqual(spy.calls, [])
        XCTAssertFalse(gate.hasReplaced)
    }

    func testUnknownBundleVersionAttachesWithoutComparing() async {
        let spy = Spy()
        spy.bundleVersion = nil
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .attach)
        XCTAssertEqual(spy.calls, [])
    }

    func testMissingBundledDaemonAttachesWithoutComparing() async {
        let spy = Spy()
        spy.hasBundledDaemon = false
        let gate = DaemonVersionGate(environment: spy.environment())
        let outcome = await gate.checkBeforeAttach(daemonSpawnedByApp: false)
        XCTAssertEqual(outcome, .attach)
        XCTAssertEqual(spy.calls, [])
    }
}
