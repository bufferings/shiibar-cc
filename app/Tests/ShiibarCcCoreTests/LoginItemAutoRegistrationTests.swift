import XCTest
@testable import ShiibarCcCore

final class LoginItemAutoRegistrationTests: XCTestCase {
    // Table-driven over the full 2x2x2 input space (DESIGN.md §4.5 / M5 T3:
    // auto-register at most once, ever, and only from a bundled launch).
    private struct Case {
        let didAutoRegisterAlready: Bool
        let runningFromBundle: Bool
        let currentlyEnabled: Bool
        let expected: Bool
        let reason: String
    }

    private static let cases: [Case] = [
        Case(
            didAutoRegisterAlready: false, runningFromBundle: true, currentlyEnabled: false,
            expected: true,
            reason: "first bundled launch, not yet enabled -> auto-register"
        ),
        Case(
            didAutoRegisterAlready: false, runningFromBundle: true, currentlyEnabled: true,
            expected: false,
            reason: "first bundled launch but already enabled -> skip the redundant register call"
        ),
        Case(
            didAutoRegisterAlready: false, runningFromBundle: false, currentlyEnabled: false,
            expected: false,
            reason: "dev (non-bundle) launch is always a no-op, even before the flag is set"
        ),
        Case(
            didAutoRegisterAlready: false, runningFromBundle: false, currentlyEnabled: true,
            expected: false,
            reason: "dev (non-bundle) launch is always a no-op regardless of current status"
        ),
        Case(
            didAutoRegisterAlready: true, runningFromBundle: true, currentlyEnabled: false,
            expected: false,
            reason: "already auto-registered once -> never again, even if the user has since turned it off"
        ),
        Case(
            didAutoRegisterAlready: true, runningFromBundle: true, currentlyEnabled: true,
            expected: false,
            reason: "already auto-registered once and still enabled -> no-op"
        ),
        Case(
            didAutoRegisterAlready: true, runningFromBundle: false, currentlyEnabled: false,
            expected: false,
            reason: "already auto-registered once, dev launch -> no-op"
        ),
        Case(
            didAutoRegisterAlready: true, runningFromBundle: false, currentlyEnabled: true,
            expected: false,
            reason: "already auto-registered once, dev launch, enabled -> no-op"
        ),
    ]

    func testShouldAutoRegisterOverAllInputCombinations() {
        for testCase in Self.cases {
            XCTAssertEqual(
                LoginItemAutoRegistration.shouldAutoRegister(
                    didAutoRegisterAlready: testCase.didAutoRegisterAlready,
                    runningFromBundle: testCase.runningFromBundle,
                    currentlyEnabled: testCase.currentlyEnabled
                ),
                testCase.expected,
                testCase.reason
            )
        }
    }
}
