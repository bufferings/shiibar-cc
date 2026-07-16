import XCTest

@testable import ShiibarCcCore

final class ResumeTerminalTests: XCTestCase {
    private func agent(_ target: String, lastSeen: Int64) -> Agent {
        Agent(
            target: target,
            status: .idle,
            unreviewed: false,
            sessionId: "s",
            cwd: "/c",
            task: nil,
            message: nil,
            since: 0,
            lastSeen: lastSeen
        )
    }

    // MARK: kind(ofTarget:)

    func testKindRecognizesBothPrefixes() {
        XCTAssertEqual(ResumeTerminal.kind(ofTarget: "iterm2:UUID"), ResumeTerminal.iterm2)
        XCTAssertEqual(
            ResumeTerminal.kind(ofTarget: "apple-terminal:/dev/ttys006"),
            ResumeTerminal.appleTerminal
        )
    }

    func testKindIsNilForUnrecognizedTargets() {
        XCTAssertNil(ResumeTerminal.kind(ofTarget: "BARE-UUID"))
        XCTAssertNil(ResumeTerminal.kind(ofTarget: "tmux:whatever"))
        XCTAssertNil(ResumeTerminal.kind(ofTarget: ""))
    }

    // MARK: decide (§4.6/T6)

    func testDecideUsesTheNewestEntrysPrefix() {
        let agents = [
            agent("iterm2:A", lastSeen: 100),
            agent("apple-terminal:/dev/ttys006", lastSeen: 200),
        ]
        // The apple-terminal entry is newer, so that wins over the remembered
        // iterm2 and the default.
        XCTAssertEqual(
            ResumeTerminal.decide(agents: agents, remembered: ResumeTerminal.iterm2),
            ResumeTerminal.appleTerminal
        )
    }

    func testDecideFallsBackToRememberedWhenNoEntries() {
        XCTAssertEqual(
            ResumeTerminal.decide(agents: [], remembered: ResumeTerminal.appleTerminal),
            ResumeTerminal.appleTerminal
        )
    }

    func testDecideFallsBackToIterm2WhenNothingKnown() {
        XCTAssertEqual(ResumeTerminal.decide(agents: [], remembered: nil), ResumeTerminal.iterm2)
    }

    func testDecideSkipsEntriesWithUnrecognizedPrefixes() {
        // The newest entry has an unknown prefix; the decision falls through
        // to the next recognized entry rather than to the remembered/default.
        let agents = [
            agent("tmux:newest", lastSeen: 300),
            agent("iterm2:B", lastSeen: 250),
        ]
        XCTAssertEqual(
            ResumeTerminal.decide(agents: agents, remembered: ResumeTerminal.appleTerminal),
            ResumeTerminal.iterm2
        )
    }
}
