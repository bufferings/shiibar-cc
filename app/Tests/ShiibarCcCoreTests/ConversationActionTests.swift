import XCTest

@testable import ShiibarCcCore

/// The Conversations bottom-panel verb derivation (M41 T1, DESIGN.md
/// §4.6/§8.48): table-driven over the four outcomes plus exact session_id
/// matching. Pure — no IO, no view.
final class ConversationActionTests: XCTestCase {
    private func summary(
        sessionID: String,
        live: Bool,
        cwd: String?
    ) -> ConversationSummary {
        ConversationSummary(sessionID: sessionID, cwd: cwd, title: nil, updatedAt: 1, live: live)
    }

    private func agent(sessionID: String, target: String) -> Agent {
        Agent(
            target: target,
            status: .idle,
            unreviewed: false,
            sessionId: sessionID,
            cwd: "/Users/example/demo",
            task: nil,
            message: nil,
            since: 0,
            lastSeen: 0
        )
    }

    // MARK: - The four outcomes (§4.6/§8.48)

    func testDeriveCoversTheFourOutcomes() {
        struct Case {
            let name: String
            let summary: ConversationSummary
            let agents: [Agent]
            let expected: ConversationAction
        }
        let cases = [
            Case(
                name: "past + cwd -> Resume enabled",
                summary: summary(sessionID: "s1", live: false, cwd: "/Users/example/demo"),
                agents: [],
                expected: .resume
            ),
            Case(
                name: "past + no cwd (nil) -> Resume disabled",
                summary: summary(sessionID: "s2", live: false, cwd: nil),
                agents: [],
                expected: .resumeDisabled
            ),
            Case(
                name: "past + empty cwd -> Resume disabled",
                summary: summary(sessionID: "s3", live: false, cwd: ""),
                agents: [],
                expected: .resumeDisabled
            ),
            Case(
                name: "live + a session_id match -> Jump carrying that target",
                summary: summary(sessionID: "s4", live: true, cwd: "/Users/example/demo"),
                agents: [agent(sessionID: "s4", target: "iterm2:UUID-4")],
                expected: .jump(target: "iterm2:UUID-4")
            ),
            Case(
                name: "live + no match -> Jump disabled",
                summary: summary(sessionID: "s5", live: true, cwd: "/Users/example/demo"),
                agents: [agent(sessionID: "other", target: "iterm2:UUID-X")],
                expected: .jumpDisabled
            ),
        ]
        for c in cases {
            XCTAssertEqual(
                ConversationAction.derive(for: c.summary, agents: c.agents),
                c.expected,
                c.name
            )
        }
    }

    // MARK: - Matching is exact session_id equality

    func testLiveMatchIsExactSessionIdEquality() {
        let sel = summary(sessionID: "abc123", live: true, cwd: "/Users/example/demo")
        // A near-miss (prefix / different case) must NOT match — no substring,
        // no fuzz.
        let agents = [
            agent(sessionID: "abc12", target: "iterm2:PREFIX"),
            agent(sessionID: "ABC123", target: "iterm2:CASE"),
            agent(sessionID: "abc123x", target: "iterm2:SUFFIX"),
        ]
        XCTAssertEqual(ConversationAction.derive(for: sel, agents: agents), .jumpDisabled)

        // The exact entry, added, wins.
        let exact = agents + [agent(sessionID: "abc123", target: "iterm2:EXACT")]
        XCTAssertEqual(
            ConversationAction.derive(for: sel, agents: exact),
            .jump(target: "iterm2:EXACT")
        )
    }

    func testLiveMatchTakesTheFirstEntryOnDuplicateSessionId() {
        // session_id is unique in practice; if two entries somehow share one,
        // the first wins (no invented defense — §8.48/M41 T1).
        let sel = summary(sessionID: "dup", live: true, cwd: "/Users/example/demo")
        let agents = [
            agent(sessionID: "dup", target: "iterm2:FIRST"),
            agent(sessionID: "dup", target: "apple-terminal:/dev/ttys001"),
        ]
        XCTAssertEqual(
            ConversationAction.derive(for: sel, agents: agents),
            .jump(target: "iterm2:FIRST")
        )
    }

    // MARK: - A live row ignores cwd; a past row ignores agents

    func testLiveRowWithNoCwdStillDerivesFromAgentsNotResume() {
        // Live rows never fall to Resume, even with a missing cwd — the live
        // branch is taken first (§4.6/§8.48).
        let sel = summary(sessionID: "s", live: true, cwd: nil)
        XCTAssertEqual(ConversationAction.derive(for: sel, agents: []), .jumpDisabled)
        XCTAssertEqual(
            ConversationAction.derive(for: sel, agents: [agent(sessionID: "s", target: "iterm2:T")]),
            .jump(target: "iterm2:T")
        )
    }

    func testPastRowIgnoresAMatchingAgent() {
        // A past row derives from cwd alone; a stray same-id agent entry does
        // not turn it into a Jump.
        let sel = summary(sessionID: "s", live: false, cwd: "/Users/example/demo")
        XCTAssertEqual(
            ConversationAction.derive(for: sel, agents: [agent(sessionID: "s", target: "iterm2:T")]),
            .resume
        )
    }
}
