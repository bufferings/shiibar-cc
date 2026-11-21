import XCTest

@testable import ShiibarCcCore

/// The bottom panel's reason lines (§4.6 "bottom panel"): the lines above
/// the button row that say why a shown button is disabled, one per distinct
/// reason. Buttons come from the same producers the list uses, so every
/// existing reason source is covered; no view, defaults, app lookup or
/// terminal is involved.
final class BottomPanelReasonTests: XCTestCase {
    private let cwd = "/Users/example/demo"
    private let untracked = "Running in a terminal Shiibar CC can't drive"
    private let iterm2Missing = "iTerm2 is not installed \u{2014} choose a terminal in Settings"
    private let ghosttyMissing = "Ghostty is not installed \u{2014} choose a terminal in Settings"
    private let ghosttyOld = "Ghostty 1.4.0 or later is required \u{2014} choose a terminal in Settings"

    private var resume: RowButton { ConversationAction.resume.button(sessionID: "h1", cwd: cwd) }
    private var noCwdResume: RowButton { ConversationAction.resumeDisabled.button(sessionID: "h1", cwd: nil) }
    private var jump: RowButton {
        ConversationAction.jump(target: "iterm2:w0t0p0:U").button(sessionID: "s1", cwd: cwd)
    }
    private var undrivableJump: RowButton { ConversationAction.jumpDisabled.button(sessionID: "s1", cwd: cwd) }
    private var branch: RowButton { ConversationAction.branchButton(sessionID: "h1", cwd: cwd) }
    private var noCwdBranch: RowButton { ConversationAction.branchButton(sessionID: "h1", cwd: nil) }
    private var noSessionBranch: RowButton { ConversationAction.branchButton(sessionID: "", cwd: cwd) }

    func testReasonsByButtons() {
        let cases: [(name: String, primary: RowButton, branch: RowButton, expected: [String])] = [
            ("none disabled: Resume and Branch", resume, branch, []),
            ("none disabled: Jump and Branch", jump, branch, []),
            ("primary only: undrivable Jump", undrivableJump, branch, [untracked]),
            ("branch only: terminal not installed", jump, branch.applying(.notInstalled(.iterm2)), [iterm2Missing]),
            ("both, same reason: terminal not installed",
             resume.applying(.notInstalled(.ghostty)), branch.applying(.notInstalled(.ghostty)), [ghosttyMissing]),
            ("both, same reason: Ghostty too old",
             resume.applying(.ghosttyTooOld), branch.applying(.ghosttyTooOld), [ghosttyOld]),
            ("both, different reasons: two lines, primary's first",
             undrivableJump, branch.applying(.ghosttyTooOld), [untracked, ghosttyOld]),
            ("both, the snapshot of an undrivable row keeps its reason",
             undrivableJump.disabled(), noSessionBranch, [untracked]),
            // A disabled button whose tooltip is only its verb has no reason.
            ("no cwd: Resume and Branch keep the verb tooltip", noCwdResume, noCwdBranch, []),
            ("no session_id: Branch keeps the verb tooltip", jump, noSessionBranch, []),
            ("refetch snapshot of a jumpable row", jump.disabled(), branch.disabled(), []),
            ("missing cwd replaced by the terminal's reason",
             noCwdResume.applying(.notInstalled(.iterm2)), noCwdBranch.applying(.notInstalled(.iterm2)),
             [iterm2Missing]),
            ("an empty tooltip is no reason",
             RowButton(kind: .resume, invocation: nil, tooltip: ""),
             RowButton(kind: .branch, invocation: nil, tooltip: ""), []),
        ]
        for testCase in cases {
            let buttons = BottomPanelButtons(primary: testCase.primary, branch: testCase.branch)
            XCTAssertEqual(buttons.disabledReasons, testCase.expected, testCase.name)
            for showsViewButton in [false, true] {
                let panel = BottomPanelModel(hints: [], buttons: buttons, showsViewButton: showsViewButton)
                XCTAssertEqual(panel.disabledReasons, testCase.expected, testCase.name)
            }
        }
    }

    /// While the buttons are not shown (placeholders), there is no reason.
    func testNoReasonWithoutButtons() {
        for showsViewButton in [false, true] {
            let panel = BottomPanelModel(hints: [], buttons: nil, showsViewButton: showsViewButton)
            XCTAssertEqual(panel.disabledReasons, [])
        }
    }

    /// Only a disabled button has a reason; an enabled button's tooltip is
    /// never one, whatever it says.
    func testDisabledReasonPerButton() {
        let cases: [(name: String, button: RowButton, expected: String?)] = [
            ("enabled Resume", resume, nil),
            ("enabled Jump", jump, nil),
            ("enabled Branch", branch, nil),
            ("enabled with a reason-like tooltip",
             RowButton(kind: .resume, invocation: .resume(sessionID: "h1", cwd: cwd), tooltip: untracked), nil),
            ("undrivable Jump", undrivableJump, untracked),
            ("Resume, iTerm2 not installed", resume.applying(.notInstalled(.iterm2)), iterm2Missing),
            ("Resume, Ghostty not installed", resume.applying(.notInstalled(.ghostty)), ghosttyMissing),
            ("Branch, Ghostty too old", branch.applying(.ghosttyTooOld), ghosttyOld),
            ("Resume without cwd", noCwdResume, nil),
            ("Branch without cwd", noCwdBranch, nil),
            ("Branch without session_id", noSessionBranch, nil),
            ("disabled Jump snapshot", jump.disabled(), nil),
        ]
        for testCase in cases {
            XCTAssertEqual(testCase.button.disabledReason, testCase.expected, testCase.name)
        }
        XCTAssertEqual(RowButton.untrackedRunningTooltip, untracked)
    }
}
