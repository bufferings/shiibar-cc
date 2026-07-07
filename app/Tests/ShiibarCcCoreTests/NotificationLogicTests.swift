import XCTest
@testable import ShiibarCcCore

final class NotificationLogicTests: XCTestCase {
    private func agent(target: String, status: AgentStatus, unreviewed: Bool) -> Agent {
        Agent(
            target: target,
            status: status,
            unreviewed: unreviewed,
            sessionId: "s-\(target)",
            cwd: "/c",
            task: nil,
            message: nil,
            since: 0,
            lastSeen: 0
        )
    }

    // ---- Notification content (§4.5) ----

    func testWaitingContentUsesLabelInTitleAndMessageAsSubtitleAndTaskAsBody() {
        let content = NotificationContentBuilder.build(
            status: .waiting,
            label: "shiibar-cc",
            message: "Claude needs your permission",
            task: "implement the docs build",
            lastAssistantMessage: nil
        )
        XCTAssertEqual(content.title, "Waiting for you — shiibar-cc")
        XCTAssertEqual(content.subtitle, "Claude needs your permission")
        XCTAssertEqual(content.body, "implement the docs build")
    }

    func testWaitingContentOmitsSubtitleAndBodyEntirelyWhenAbsent() {
        let content = NotificationContentBuilder.build(
            status: .waiting,
            label: "shiibar-cc",
            message: nil,
            task: nil,
            lastAssistantMessage: nil
        )
        XCTAssertEqual(content.title, "Waiting for you — shiibar-cc")
        XCTAssertNil(content.subtitle)
        XCTAssertNil(content.body)
    }

    func testDoneContentUsesLabelInTitleAndLastAssistantMessageAsBodyAndNeverHasASubtitle() {
        let content = NotificationContentBuilder.build(
            status: .idle,
            label: "shiibar-cc",
            message: "should be ignored for done",
            task: "implement the docs build",
            lastAssistantMessage: "Done. All 54 tests pass."
        )
        XCTAssertEqual(content.title, "Done — shiibar-cc")
        XCTAssertNil(content.subtitle, "done never has a subtitle (§4.5)")
        XCTAssertEqual(content.body, "Done. All 54 tests pass.")
    }

    func testDoneContentFallsBackToTaskWhenLastAssistantMessageIsAbsent() {
        let content = NotificationContentBuilder.build(
            status: .idle,
            label: "shiibar-cc",
            message: nil,
            task: "implement the docs build",
            lastAssistantMessage: nil
        )
        XCTAssertEqual(content.body, "implement the docs build")
    }

    func testDoneContentOmitsBodyEntirelyWhenNeitherLastAssistantMessageNorTaskIsPresent() {
        let content = NotificationContentBuilder.build(
            status: .idle,
            label: "shiibar-cc",
            message: nil,
            task: nil,
            lastAssistantMessage: nil
        )
        XCTAssertNil(content.body)
    }

    // ---- UnreviewedEdgeTracker: rising-edge detection + de-dup ----

    func testFirstObservationOfAnUnreviewedAgentIsARisingEdge() {
        let tracker = UnreviewedEdgeTracker()
        let edges = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        XCTAssertEqual(edges, [UnreviewedEdge(target: "t", status: .waiting)])
    }

    func testRepeatedObservationOfTheSameStillUnreviewedAgentDoesNotFireAgain() {
        // This is the DESIGN.md §4.5 "de-dupe via fired record" requirement:
        // a snapshot and a later reconcile both reporting the same
        // still-unreviewed agent must only notify once.
        let tracker = UnreviewedEdgeTracker()
        _ = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        let secondEdges = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        XCTAssertTrue(secondEdges.isEmpty)
    }

    func testUnreviewedGoingFalseThenTrueAgainIsANewRisingEdge() {
        let tracker = UnreviewedEdgeTracker()
        _ = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        _ = tracker.observe(agents: [agent(target: "t", status: .working, unreviewed: false)])
        let edges = tracker.observe(agents: [agent(target: "t", status: .idle, unreviewed: true)])
        XCTAssertEqual(edges, [UnreviewedEdge(target: "t", status: .idle)])
    }

    // ---- Baseline (first-snapshot) seeding (§4.5 2026-07-05 addendum) ----

    func testBaselineSnapshotWithPreExistingUnreviewedFiresNoEdges() {
        let tracker = UnreviewedEdgeTracker()
        let edges = tracker.observe(
            agents: [agent(target: "t", status: .waiting, unreviewed: true)],
            baseline: true
        )
        XCTAssertTrue(edges.isEmpty, "the launch baseline must not re-notify a pre-existing unreviewed entry")
        XCTAssertEqual(tracker.trackedTargets, ["t"], "baseline still seeds the tracked set, just without firing")
    }

    func testBaselineSeededEntryDroppingThenRisingAgainLaterFires() {
        let tracker = UnreviewedEdgeTracker()
        _ = tracker.observe(
            agents: [agent(target: "t", status: .waiting, unreviewed: true)],
            baseline: true
        )
        _ = tracker.observe(agents: [agent(target: "t", status: .working, unreviewed: false)])
        let edges = tracker.observe(agents: [agent(target: "t", status: .idle, unreviewed: true)])
        XCTAssertEqual(edges, [UnreviewedEdge(target: "t", status: .idle)])
    }

    func testSecondSnapshotAfterBaselineFiresForANewUnreviewedEntry() {
        // A reconnect snapshot is not the launch baseline, so it must keep
        // the ordinary rising-edge behavior (DESIGN.md §4.5: "reconnect
        // snapshot / reconcile" edges still fire).
        let tracker = UnreviewedEdgeTracker()
        _ = tracker.observe(
            agents: [agent(target: "t", status: .waiting, unreviewed: true)],
            baseline: true
        )
        let edges = tracker.observe(agents: [
            agent(target: "t", status: .waiting, unreviewed: true),
            agent(target: "u", status: .idle, unreviewed: true),
        ])
        XCTAssertEqual(edges, [UnreviewedEdge(target: "u", status: .idle)])
    }

    func testLiveEventRisingEdgeAfterBaselineFires() {
        let tracker = UnreviewedEdgeTracker()
        _ = tracker.observe(
            agents: [agent(target: "t", status: .working, unreviewed: false)],
            baseline: true
        )
        let edges = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        XCTAssertEqual(edges, [UnreviewedEdge(target: "t", status: .waiting)])
    }

    func testForgetAllowsTheSameTargetToRiseAgainAsANewEdge() {
        let tracker = UnreviewedEdgeTracker()
        _ = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        tracker.forget(target: "t")
        let edges = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        XCTAssertEqual(edges, [UnreviewedEdge(target: "t", status: .waiting)])
    }

    // ---- Delayed re-check (§4.5/§8.16: no foreground suppression) ----

    func testDelayedNotificationFiresOnlyWhenStillUnreviewed() {
        XCTAssertTrue(DelayedNotificationDecision.shouldNotify(currentlyUnreviewed: true))
        XCTAssertFalse(DelayedNotificationDecision.shouldNotify(currentlyUnreviewed: false))
    }

    // ---- Notification sound policy (§4.5/§8.26/§8.27: Mute Banners is
    // gone, the banner always delivers — only the attached sound is gated by
    // Mute Sound and the event's own Waiting/Done sound choice) ----

    func testWaitingEdgeUsesWaitingSoundWhenNotMuted() {
        let name = NotificationSoundPolicy.soundName(
            status: .waiting, waitingSoundName: "Ping", doneSoundName: "Glass", muted: false
        )
        XCTAssertEqual(name, "Ping")
    }

    func testDoneEdgeUsesDoneSoundWhenNotMuted() {
        let name = NotificationSoundPolicy.soundName(
            status: .idle, waitingSoundName: "Ping", doneSoundName: "Glass", muted: false
        )
        XCTAssertEqual(name, "Glass")
    }

    func testMutedSuppressesTheSoundRegardlessOfStatus() {
        XCTAssertNil(NotificationSoundPolicy.soundName(
            status: .waiting, waitingSoundName: "Ping", doneSoundName: "Glass", muted: true
        ))
        XCTAssertNil(NotificationSoundPolicy.soundName(
            status: .idle, waitingSoundName: "Ping", doneSoundName: "Glass", muted: true
        ))
    }

    // ---- Cleanup rule ----

    func testCleanupSweepsForEveryReasonExceptSessionEnd() {
        XCTAssertFalse(NotificationCleanupRule.shouldSweep(onRemovalReason: .sessionEnd))
        XCTAssertTrue(NotificationCleanupRule.shouldSweep(onRemovalReason: .stale))
        XCTAssertTrue(NotificationCleanupRule.shouldSweep(onRemovalReason: .remove))
        XCTAssertTrue(NotificationCleanupRule.shouldSweep(onRemovalReason: .prune))
        XCTAssertTrue(NotificationCleanupRule.shouldSweep(onRemovalReason: .unknown))
    }
}
