import XCTest

@testable import ShiibarCcCore

/// Whether a target is jumpable, from its prefix alone (DESIGN.md §2, §4.2
/// "protocol contract": target kinds). The outcomes match the client's
/// routing (§4.3 "routing rules").
final class TargetJumpabilityTests: XCTestCase {
    func testJumpableTargets() {
        let jumpable = [
            "iterm2:ABCD-1234",
            "apple-terminal:/dev/ttys006",
            "ghostty:/dev/ttys005",
            // No `:`: a bare iTerm2 UUID (pre-prefix / hand-typed form).
            "ABCD-1234",
            // `wNtNpN:UUID`: a hand-pasted $ITERM_SESSION_ID.
            "w0t0p0:ABCD-1234",
            "w12t3p45:ABCD-1234",
        ]
        for target in jumpable {
            XCTAssertTrue(TargetJumpability.canJump(target), target)
        }
    }

    func testTargetsThatCannotJump() {
        let notJumpable = [
            // A session in a terminal the app can't drive (§2).
            "process:48213",
            // Prefixes the app does not know (§4.2).
            "tmux:whatever",
            "vscode:1234",
            "ITERM2:ABCD-1234",
            // Not the `wNtNpN` shape, or nothing after the `:` — the client
            // routes these to no terminal module.
            "w0t0:ABCD-1234",
            "w0t0p0x:ABCD-1234",
            "wtp:ABCD-1234",
            "w0t0p0:",
            ":ABCD-1234",
            "",
        ]
        for target in notJumpable {
            XCTAssertFalse(TargetJumpability.canJump(target), target)
        }
    }
}
