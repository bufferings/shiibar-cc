import AppKit
import XCTest
@testable import ShiibarCcApp

/// The §8.43 raise-or-open helper: an existing window is brought back
/// (deminiaturize + front — asserted via visibility, since key status
/// needs a focused app the test process is not); a missing title reports
/// false so callers open fresh. Raising must not move the window.
@MainActor
final class WindowRaiseTests: XCTestCase {
    func testRaiseReportsFalseWithNoSuchWindow() {
        let state = AppState(helpersDirectory: nil)
        XCTAssertFalse(state.raiseWindow(titled: "No Such Window"))
    }

    func testRaiseBringsAnExistingWindowBackWithoutMovingIt() {
        let state = AppState(helpersDirectory: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 123, y: 145, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        // ARC holds the reference; the default release-on-close would
        // double-free under XCTest (measured: signal 11).
        window.isReleasedWhenClosed = false
        window.title = "Agents"
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        let frameBefore = window.frame

        XCTAssertTrue(state.raiseWindow(titled: "Agents"))
        XCTAssertTrue(window.isVisible, "the raise must order the window back in")
        XCTAssertEqual(window.frame, frameBefore, "raising must not move an existing window")
        window.orderOut(nil)
    }
}
