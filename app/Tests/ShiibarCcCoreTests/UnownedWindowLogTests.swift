import XCTest
@testable import ShiibarCcCore

/// DESIGN.md §4.5 "making failures visible": a window the app did not
/// create is logged once while shown; the windows the app shows in normal
/// use are never logged.
final class UnownedWindowLogTests: XCTestCase {
    func testWindowsTheAppShowsAreNotRecorded() {
        let ownKinds: [ShownWindowKind] = [.popover, .mainWindow, .settings, .aboutPanel, .menu, .tooltip, .statusItem]
        for kind in ownKinds {
            XCTAssertFalse(UnownedWindowLog.shouldRecord(kind: kind, recordedWhileShown: false), "\(kind)")
            XCTAssertFalse(UnownedWindowLog.shouldRecord(kind: kind, recordedWhileShown: true), "\(kind)")
        }
    }

    func testOtherWindowsAreRecordedOncePerShowing() {
        XCTAssertTrue(UnownedWindowLog.shouldRecord(kind: .other, recordedWhileShown: false))
        XCTAssertFalse(UnownedWindowLog.shouldRecord(kind: .other, recordedWhileShown: true))
    }

    func testTrackerRecordsOnceWhileShownAndAgainAfterHiding() {
        var tracker = UnownedWindowTracker()
        XCTAssertTrue(tracker.windowShown(1, kind: .other))
        XCTAssertFalse(tracker.windowShown(1, kind: .other), "still shown: not twice")
        XCTAssertTrue(tracker.windowShown(2, kind: .other), "another window")
        tracker.windowHidden(1)
        XCTAssertTrue(tracker.windowShown(1, kind: .other), "shown again after hiding (a reused panel)")
        XCTAssertFalse(tracker.windowShown(3, kind: .menu))
        XCTAssertFalse(tracker.windowShown(4, kind: .popover))
    }

    func testLineNamesTheClassSizeAndLevel() {
        XCTAssertEqual(UnownedWindowLog.line(className: "ExamplePanel", width: 320.4, height: 48, level: 3),
                       "window not created by the app shown: class=ExamplePanel size=320x48 level=3")
    }

    /// Windows the app holds no handle for are told apart by class name
    /// only; a panel of another class is `.other`.
    func testKindFromClassName() {
        XCTAssertEqual(UnownedWindowLog.kind(className: "ExampleMenuWindow"), .menu)
        XCTAssertEqual(UnownedWindowLog.kind(className: "ExampleToolTipPanel"), .tooltip)
        XCTAssertEqual(UnownedWindowLog.kind(className: "ExamplePopoverWindow"), .popover)
        XCTAssertEqual(UnownedWindowLog.kind(className: "ExampleStatusBarWindow"), .statusItem)
        XCTAssertEqual(UnownedWindowLog.kind(className: "ExampleInputPanel"), .other)
    }

    /// §9: the window list is read 0.5 and 2 seconds after a surface shows.
    func testScanDelays() {
        XCTAssertEqual(UnownedWindowLog.scanDelays, [0.5, 2])
    }

    private func scanned(_ number: Int, _ className: String?, _ kind: ShownWindowKind, level: Int = 101) -> ScannedWindow {
        ScannedWindow(number: number, className: className, kind: kind, width: 300, height: 40, level: level)
    }

    /// The window list logs the unowned windows — a window with no
    /// matching `NSWindow` under a marker — and not the app's own.
    func testScanLogsUnownedAndUnmatchedWindows() {
        var tracker = UnownedWindowTracker()
        let lines = tracker.scanned([
            scanned(1, "ExamplePopoverWindow", .popover),
            scanned(2, "ExampleInputPanel", .other),
            scanned(3, nil, .other),
            scanned(4, "ExampleMenuWindow", .menu),
        ])
        XCTAssertEqual(lines, [
            "window not created by the app shown: class=ExampleInputPanel size=300x40 level=101",
            "window not created by the app shown: class=<no NSWindow> size=300x40 level=101",
        ])
    }

    /// Once per showing across both detections: a window the notifications
    /// logged is not logged again by the list, and vice versa; a window
    /// missing from a later list counts as hidden and is logged again when
    /// it reappears.
    func testOncePerShowingAcrossBothDetections() {
        var tracker = UnownedWindowTracker()
        XCTAssertTrue(tracker.windowShown(7, kind: .other))
        XCTAssertEqual(tracker.scanned([scanned(7, "ExampleInputPanel", .other)]), [])
        XCTAssertEqual(tracker.scanned([scanned(8, nil, .other)]).count, 1, "7 is gone from the list")
        XCTAssertFalse(tracker.windowShown(8, kind: .other), "logged by the list already")
        XCTAssertTrue(tracker.windowShown(7, kind: .other), "7 reappeared")
        XCTAssertEqual(tracker.scanned([scanned(7, "ExampleInputPanel", .other), scanned(8, nil, .other)]), [])
    }
}
