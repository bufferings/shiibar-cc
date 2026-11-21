import XCTest

@testable import ShiibarCcCore

/// When the app is a regular app (DESIGN.md §4.5 "the app is a regular app
/// only while the window is open", §8.61) and when a hotkey-opened window
/// moves the focus to the list (§4.5 "global hotkey").
final class SurfaceActivationTests: XCTestCase {
    // MARK: - RegularAppHold

    func testWindowOpenAndOrdinaryCloseSwitchAtOnce() {
        var hold = RegularAppHold()
        XCTAssertEqual(hold.holder, .none)
        XCTAssertEqual(hold.windowOpened(), .switchToRegular)
        XCTAssertTrue(hold.allowsDeferredActivation)
        // Red button, ⌘W, tray click, hotkey: back to accessory at once.
        XCTAssertEqual(hold.windowClosed(forOpenInPopover: false), .switchToAccessory)
        XCTAssertEqual(hold.holder, .none)
        XCTAssertFalse(hold.allowsDeferredActivation, "a window closed before the delayed activation")
        XCTAssertNil(hold.popoverClosed(), "an ordinary popover close changes nothing")
    }

    func testOpenInPopoverKeepsTheAppRegularUntilThePopoverCloses() {
        var hold = RegularAppHold()
        _ = hold.windowOpened()
        XCTAssertNil(hold.windowClosed(forOpenInPopover: true), "no switch while the popover opens")
        XCTAssertEqual(hold.holder, .popoverFromWindow)
        XCTAssertFalse(hold.allowsDeferredActivation)
        XCTAssertEqual(hold.popoverClosed(), .switchToAccessory)
        XCTAssertEqual(hold.holder, .none)
        XCTAssertNil(hold.popoverClosed(), "only once")
    }

    /// When the popover `Open in popover` meant to show is not shown, the
    /// app reports a popover close, which releases the hold.
    func testPopoverThatFailsToShowAfterOpenInPopoverReleasesTheHold() {
        var hold = RegularAppHold()
        _ = hold.windowOpened()
        _ = hold.windowClosed(forOpenInPopover: true)
        XCTAssertEqual(hold.popoverClosed(), .switchToAccessory)
        XCTAssertEqual(hold.holder, .none)
        XCTAssertEqual(hold.windowOpened(), .switchToRegular, "a later open switches again")
    }

    func testOpenInWindowFromThatPopoverStaysRegularWithoutASecondSwitch() {
        var hold = RegularAppHold()
        _ = hold.windowOpened()
        _ = hold.windowClosed(forOpenInPopover: true)
        XCTAssertNil(hold.windowOpened(), "already regular")
        XCTAssertEqual(hold.holder, .window, "held by the one open window")
        XCTAssertNil(hold.popoverClosed(), "the popover closing as the window opens keeps the app regular")
        XCTAssertEqual(hold.windowClosed(forOpenInPopover: false), .switchToAccessory, "one close ends it")
        XCTAssertNil(hold.windowClosed(forOpenInPopover: false), "no second switch")
    }

    func testRepeatedOpenReportsDoNotSwitchTwice() {
        var hold = RegularAppHold()
        XCTAssertEqual(hold.windowOpened(), .switchToRegular)
        XCTAssertNil(hold.windowOpened())
        XCTAssertEqual(hold.windowClosed(forOpenInPopover: false), .switchToAccessory)
    }

    func testCloseWithoutAnOpenWindowDoesNothing() {
        var hold = RegularAppHold()
        XCTAssertNil(hold.windowClosed(forOpenInPopover: false))
        XCTAssertNil(hold.windowClosed(forOpenInPopover: true))
        XCTAssertEqual(hold.holder, .none)
    }

    // MARK: - PendingListFocus

    func testHotKeyOpenIsConsumedOnceByTheNextBecomeKey() {
        var pending = PendingListFocus()
        XCTAssertNil(pending.windowBecameKey(at: 10), "nothing pending")
        pending.opened(for: .hotKey, at: 10)
        XCTAssertTrue(pending.isPending)
        XCTAssertEqual(pending.windowBecameKey(at: 10.1), .hotKey)
        XCTAssertNil(pending.windowBecameKey(at: 10.2), "used once")
    }

    func testRaiseOrCloseClearsThePendingFocus() {
        for purpose in [PendingListFocus.Purpose.hotKey, .notification(target: "process:4242")] {
            var pending = PendingListFocus()
            let id = pending.opened(for: purpose, at: 10)
            pending.clear()
            XCTAssertFalse(pending.isPending, "\(purpose)")
            XCTAssertNil(pending.windowBecameKey(at: 10.1), "\(purpose)")
            XCTAssertNil(pending.timeoutDue(id: id), "\(purpose)")
        }
    }

    func testExpiredPendingFocusIsIgnoredAndDropped() {
        XCTAssertEqual(PendingListFocus.validSeconds, 1)
        var pending = PendingListFocus()
        pending.opened(for: .hotKey, at: 10)
        XCTAssertEqual(pending.windowBecameKey(at: 10 + PendingListFocus.validSeconds), .hotKey, "at the limit")
        let id = pending.opened(for: .hotKey, at: 10)
        XCTAssertNil(pending.windowBecameKey(at: 11.5), "a later key change is the user's own")
        XCTAssertFalse(pending.isPending)
        XCTAssertNil(pending.timeoutDue(id: id), "the timeout runs nothing for the hotkey")
    }

    /// A notification click that opened the window from closed selects the
    /// row once the window has become key, under the same time limit as
    /// the hotkey.
    func testNotificationOpenIsConsumedByTheNextBecomeKeyWithinTheLimit() {
        let target = "process:4242"
        var pending = PendingListFocus()
        let id = pending.opened(for: .notification(target: target), at: 10)
        XCTAssertEqual(pending.windowBecameKey(at: 10 + PendingListFocus.validSeconds), .notification(target: target))
        XCTAssertNil(pending.windowBecameKey(at: 10.2), "used once")
        XCTAssertNil(pending.timeoutDue(id: id), "the timeout finds nothing left")
    }

    /// The window does not become key in time: the row is still selected,
    /// at the timeout; a later key change is the user's own and runs
    /// nothing.
    func testNotificationOpenRunsAtTheTimeoutWhenTheWindowDidNotBecomeKey() {
        let target = "process:4242"
        var pending = PendingListFocus()
        let id = pending.opened(for: .notification(target: target), at: 10)
        XCTAssertNil(pending.windowBecameKey(at: 11.5), "past the limit")
        XCTAssertTrue(pending.isPending, "kept for the timeout")
        XCTAssertEqual(pending.timeoutDue(id: id), .notification(target: target))
        XCTAssertNil(pending.timeoutDue(id: id), "once")
        XCTAssertNil(pending.windowBecameKey(at: 11.6))
    }

    /// A newer open replaces the pending one: the older timeout runs
    /// nothing.
    func testANewerOpenReplacesThePendingOne() {
        var pending = PendingListFocus()
        let older = pending.opened(for: .notification(target: "process:1"), at: 10)
        let newer = pending.opened(for: .notification(target: "process:2"), at: 10.5)
        XCTAssertNil(pending.timeoutDue(id: older))
        XCTAssertEqual(pending.timeoutDue(id: newer), .notification(target: "process:2"))
    }
}
