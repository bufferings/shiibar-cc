import AppKit
import XCTest
@testable import ShiibarCcApp

/// DESIGN.md §4.5 "popover" / §8.58: when the app resigns active, the
/// popover closes if it is shown — also after a menu was opened from inside
/// it, where AppKit stops closing a `.transient` popover by itself. The
/// notifications come from a private center, so no real popover, window or
/// app activation is involved.
@MainActor
final class PopoverDeactivationCloserTests: XCTestCase {
    private func post(_ name: Notification.Name, to center: NotificationCenter) {
        center.post(name: name, object: nil)
    }

    func testResignActiveClosesTheShownPopover() {
        let center = NotificationCenter()
        var closes = 0
        let closer = PopoverDeactivationCloser(center: center, isPopoverShown: { true }, closePopover: { closes += 1 })
        post(NSApplication.didResignActiveNotification, to: center)
        XCTAssertEqual(closes, 1)
        post(NSApplication.didResignActiveNotification, to: center)
        XCTAssertEqual(closes, 2, "every deactivation while shown closes it")
        withExtendedLifetime(closer) {}
    }

    func testResignActiveDoesNothingWhileThePopoverIsNotShown() {
        let center = NotificationCenter()
        var closes = 0
        let closer = PopoverDeactivationCloser(center: center, isPopoverShown: { false }, closePopover: { closes += 1 })
        post(NSApplication.didResignActiveNotification, to: center)
        XCTAssertEqual(closes, 0, "the window alone is never closed by a deactivation")
        withExtendedLifetime(closer) {}
    }

    func testOtherActivationNotificationsDoNotClose() {
        let center = NotificationCenter()
        var closes = 0
        let closer = PopoverDeactivationCloser(center: center, isPopoverShown: { true }, closePopover: { closes += 1 })
        post(NSApplication.didBecomeActiveNotification, to: center)
        post(NSApplication.willResignActiveNotification, to: center)
        XCTAssertEqual(closes, 0)
        withExtendedLifetime(closer) {}
    }

    func testReleasedCloserStopsObserving() {
        let center = NotificationCenter()
        var closes = 0
        var closer: PopoverDeactivationCloser? = PopoverDeactivationCloser(
            center: center, isPopoverShown: { true }, closePopover: { closes += 1 })
        XCTAssertNotNil(closer)
        closer = nil
        post(NSApplication.didResignActiveNotification, to: center)
        XCTAssertEqual(closes, 0)
    }
}
