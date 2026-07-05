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

    // ---- Mute delivery decision (§4.5/§8.14 2026-07-05: independent Mute
    // Banners / Mute Sound switches, all four combinations valid) ----

    func testNeitherMutedDeliversBannerWithAttachedSound() {
        let decision = NotificationDeliveryPolicy.decide(muteBanners: false, muteSound: false)
        XCTAssertTrue(decision.deliverBanner)
        XCTAssertTrue(decision.attachBannerSound)
        XCTAssertFalse(decision.playStandaloneSound)
    }

    func testMuteSoundOnlyDeliversBannerWithoutSound() {
        let decision = NotificationDeliveryPolicy.decide(muteBanners: false, muteSound: true)
        XCTAssertTrue(decision.deliverBanner)
        XCTAssertFalse(decision.attachBannerSound)
        XCTAssertFalse(decision.playStandaloneSound)
    }

    func testMuteBannersOnlyIsSoundOnlyModeWithNoBanner() {
        let decision = NotificationDeliveryPolicy.decide(muteBanners: true, muteSound: false)
        XCTAssertFalse(decision.deliverBanner)
        XCTAssertFalse(decision.attachBannerSound, "no banner is delivered, so there's nothing to attach a sound to")
        XCTAssertTrue(decision.playStandaloneSound, "Mute Banners only plays the sound directly (§4.5 sound-only mode)")
    }

    func testBothMutedDeliversNothingAndPlaysNothing() {
        let decision = NotificationDeliveryPolicy.decide(muteBanners: true, muteSound: true)
        XCTAssertFalse(decision.deliverBanner)
        XCTAssertFalse(decision.attachBannerSound)
        XCTAssertFalse(decision.playStandaloneSound)
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
