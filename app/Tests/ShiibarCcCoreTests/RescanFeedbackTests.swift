import XCTest
@testable import ShiibarCcCore

final class RescanFeedbackTests: XCTestCase {
    func testExitZeroIsSuccess() {
        XCTAssertEqual(RescanFeedback.forFinishedExitCode(0), .success)
    }

    func testExitThreeTCCYieldsNoTransientFeedback() {
        // Exit 3 keeps going through the existing warning-row path
        // (AppState.noteExitCode) unchanged — it must not also flash
        // "Rescan failed" here (M5 T2 brief).
        XCTAssertNil(RescanFeedback.forFinishedExitCode(3))
    }

    func testAnyOtherNonzeroExitIsFailure() {
        for code: Int32 in [1, 2, 124, -1] {
            XCTAssertEqual(RescanFeedback.forFinishedExitCode(code), .failure, "exit \(code)")
        }
    }

    func testDisplaySecondsMatchesDesignConstant() {
        // DESIGN.md §9: Rescan transient-display duration = 2 seconds.
        XCTAssertEqual(RescanFeedback.displaySeconds, 2)
    }
}
