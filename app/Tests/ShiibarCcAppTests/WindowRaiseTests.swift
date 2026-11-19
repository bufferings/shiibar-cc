import AppKit
import XCTest
@testable import ShiibarCcApp

/// The §8.43 raise used for the main window (tray click or hotkey while the
/// window is open and not frontmost, Dock click / reopen) and for the windows the ⌄ menu opens: an
/// existing window is brought back (deminiaturize + front — asserted via
/// visibility, since key status needs a focused app the test process is
/// not). Raising must not move the window.
@MainActor
final class WindowRaiseTests: XCTestCase {
    func testRaiseBringsAnExistingWindowBackWithoutMovingIt() {
        let window = NSWindow(
            contentRect: NSRect(x: 123, y: 145, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        // ARC holds the reference; the default release-on-close would
        // double-free under XCTest (measured: signal 11).
        window.isReleasedWhenClosed = false
        window.title = "Shiibar CC"
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        let frameBefore = window.frame

        MainSurfaceController.raise(window)
        XCTAssertTrue(window.isVisible, "the raise must order the window back in")
        XCTAssertEqual(window.frame, frameBefore, "raising must not move an existing window")
        window.orderOut(nil)
    }
}
