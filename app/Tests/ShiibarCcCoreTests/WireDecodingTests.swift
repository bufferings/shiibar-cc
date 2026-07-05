// NDJSON / SubscribeEvent decoding tests (DESIGN.md §4.2): unknown event /
// status / fields must be ignored (forward compat), never fail the line.

import XCTest
@testable import ShiibarCcCore

final class WireDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> SubscribeEvent {
        try JSONDecoder().decode(SubscribeEvent.self, from: Data(json.utf8))
    }

    func testSnapshotDecodesAgentsArray() throws {
        let json = """
        {"event":"snapshot","agents":[{"target":"t","status":"waiting","unreviewed":true,\
        "session_id":"s","cwd":"/c","task":"do it","message":"perm","since":1,"last_seen":2}]}
        """
        guard case .snapshot(let agents) = try decode(json) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].target, "t")
        XCTAssertEqual(agents[0].status, .waiting)
        XCTAssertTrue(agents[0].unreviewed)
        XCTAssertEqual(agents[0].sessionId, "s")
        XCTAssertEqual(agents[0].task, "do it")
        XCTAssertEqual(agents[0].message, "perm")
        XCTAssertEqual(agents[0].since, 1)
        XCTAssertEqual(agents[0].lastSeen, 2)
    }

    func testAgentWithoutTaskOrMessageDecodesToNil() throws {
        let json = """
        {"event":"status_changed","agent":{"target":"t","status":"idle","unreviewed":false,\
        "session_id":"s","cwd":"/c","since":1,"last_seen":2}}
        """
        guard case .statusChanged(let agent) = try decode(json) else {
            return XCTFail("expected status_changed")
        }
        XCTAssertNil(agent.task)
        XCTAssertNil(agent.message)
        XCTAssertNil(agent.lastAssistantMessage, "pre-M5 wire line has no such field at all (backward compat)")
    }

    func testAgentDecodesLastAssistantMessageWhenPresent() throws {
        // §4.2: `last_assistant_message` is a forward-compatible addition
        // to the wire `Agent` (M5 T4).
        let json = """
        {"event":"status_changed","agent":{"target":"t","status":"idle","unreviewed":true,\
        "session_id":"s","cwd":"/c","last_assistant_message":"Done. All 54 tests pass.",\
        "since":1,"last_seen":2}}
        """
        guard case .statusChanged(let agent) = try decode(json) else {
            return XCTFail("expected status_changed")
        }
        XCTAssertEqual(agent.lastAssistantMessage, "Done. All 54 tests pass.")
    }

    func testAgentDecodesCreatedAtAndLastReportAtWhenPresent() throws {
        // §4.2/§3.6: `created_at` / `last_report_at` are the sort keys for
        // the dropdown's "Newest session" / "Recent activity" modes (M5 T9).
        let json = """
        {"event":"status_changed","agent":{"target":"t","status":"idle","unreviewed":true,\
        "session_id":"s","cwd":"/c","created_at":100,"last_report_at":200,"since":1,"last_seen":2}}
        """
        guard case .statusChanged(let agent) = try decode(json) else {
            return XCTFail("expected status_changed")
        }
        XCTAssertEqual(agent.createdAt, 100)
        XCTAssertEqual(agent.lastReportAt, 200)
    }

    func testAgentWithoutCreatedAtOrLastReportAtDefaultsToZero() throws {
        // Backward compat: a pre-M5 daemon's `Agent` line has neither key
        // at all (M5 T9) — both must default to 0 rather than failing.
        let json = """
        {"event":"status_changed","agent":{"target":"t","status":"idle","unreviewed":false,\
        "session_id":"s","cwd":"/c","since":1,"last_seen":2}}
        """
        guard case .statusChanged(let agent) = try decode(json) else {
            return XCTFail("expected status_changed")
        }
        XCTAssertEqual(agent.createdAt, 0)
        XCTAssertEqual(agent.lastReportAt, 0)
    }

    func testAgentRemovedDecodesTargetAndReason() throws {
        let json = #"{"event":"agent_removed","target":"t","reason":"session_end"}"#
        guard case .agentRemoved(let target, let reason) = try decode(json) else {
            return XCTFail("expected agent_removed")
        }
        XCTAssertEqual(target, "t")
        XCTAssertEqual(reason, .sessionEnd)
    }

    func testAgentRemovedMissingReasonFallsBackToUnknown() throws {
        // Pre-M4 wire compat: a line with no `reason` field at all.
        let json = #"{"event":"agent_removed","target":"t"}"#
        guard case .agentRemoved(_, let reason) = try decode(json) else {
            return XCTFail("expected agent_removed")
        }
        XCTAssertEqual(reason, .unknown)
    }

    func testAgentRemovedUnrecognizedReasonFallsBackToUnknown() throws {
        let json = #"{"event":"agent_removed","target":"t","reason":"some_future_reason"}"#
        guard case .agentRemoved(_, let reason) = try decode(json) else {
            return XCTFail("expected agent_removed")
        }
        XCTAssertEqual(reason, .unknown)
    }

    func testUnrecognizedEventFallsBackToUnknownRatherThanFailing() throws {
        let json = #"{"event":"some_future_event","foo":"bar"}"#
        XCTAssertEqual(try decode(json), .unknown)
    }

    func testUnrecognizedStatusFallsBackToUnknownRatherThanFailing() throws {
        let json = """
        {"event":"status_changed","agent":{"target":"t","status":"some_future_status",\
        "unreviewed":false,"session_id":"s","cwd":"/c","since":1,"last_seen":2}}
        """
        guard case .statusChanged(let agent) = try decode(json) else {
            return XCTFail("expected status_changed")
        }
        XCTAssertEqual(agent.status, .unknown)
    }

    func testUnknownExtraFieldsAreIgnored() throws {
        let json = """
        {"event":"status_changed","agent":{"target":"t","status":"idle","unreviewed":false,\
        "session_id":"s","cwd":"/c","since":1,"last_seen":2,"some_future_field":42}}
        """
        guard case .statusChanged(let agent) = try decode(json) else {
            return XCTFail("expected status_changed")
        }
        XCTAssertEqual(agent.target, "t")
    }

    func testNDJSONLineBufferSplitsChunksAcrossMultipleFeeds() {
        let buffer = NDJSONLineBuffer()
        let line1 = #"{"event":"agent_removed","target":"a","reason":"remove"}"#
        let line2 = #"{"event":"agent_removed","target":"b","reason":"stale"}"#
        // Feed the first line split across two chunks, plus a second full line.
        let firstChunkEvents = buffer.feed(Data((String(line1.prefix(10))).utf8))
        XCTAssertTrue(firstChunkEvents.isEmpty, "a partial line must not yield an event yet")

        let rest = String(line1.dropFirst(10)) + "\n" + line2 + "\n"
        let events = buffer.feed(Data(rest.utf8))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0], .agentRemoved(target: "a", reason: .remove))
        XCTAssertEqual(events[1], .agentRemoved(target: "b", reason: .stale))
    }

    func testNDJSONLineBufferSkipsAMalformedLineWithoutLosingSubsequentLines() {
        let buffer = NDJSONLineBuffer()
        let malformed = "{not json}\n"
        let valid = #"{"event":"agent_removed","target":"a","reason":"remove"}"# + "\n"
        let events = buffer.feed(Data((malformed + valid).utf8))
        XCTAssertEqual(events, [.agentRemoved(target: "a", reason: .remove)])
    }
}
