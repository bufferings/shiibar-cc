import AppKit
import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The on-screen window list detection of windows the app did not create
/// (DESIGN.md §4.5 "making failures visible", §9): read 0.5 and 2 seconds
/// after a surface shows, matched to `NSWindow`s by number. The window
/// list, the lookup, the timer, the log and the notification center are
/// injected: the real screen is never read, and the `NSWindow`s here are
/// never shown.
@MainActor
final class UnownedWindowMonitorTests: XCTestCase {
    private var list: [OnScreenWindowInfo] = []
    private var windows: [Int: NSWindow] = [:]
    private var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
    private var lines: [String] = []
    private var center = NotificationCenter()
    /// The windows the notification path sees as shown.
    private var shown: Set<ObjectIdentifier> = []
    private var assignedNumbers: [ObjectIdentifier: Int] = [:]

    private final class ExampleInputPanel: NSPanel {}

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        list = []
        windows = [:]
        scheduled = []
        lines = []
        center = NotificationCenter()
        shown = []
        assignedNumbers = [:]
    }

    private func makeMonitor(ownWindow: NSWindow? = nil) -> UnownedWindowMonitor {
        UnownedWindowMonitor(
            center: center,
            kind: { window in
                if let ownWindow, window === ownWindow { return .mainWindow }
                return UnownedWindowLog.kind(className: String(describing: type(of: window)))
            },
            log: { [unowned self] in self.lines.append($0) },
            listWindows: { [unowned self] in self.list },
            windowForNumber: { [unowned self] in self.windows[$0] },
            isShown: { [unowned self] in self.shown.contains(ObjectIdentifier($0)) },
            numberOf: { [unowned self] in self.assignedNumbers[ObjectIdentifier($0)] ?? -1 },
            schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) })
    }

    private func makeWindow<W: NSWindow>(_ type: W.Type) -> W {
        let window = W(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                       styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func runScheduled() {
        let work = scheduled
        scheduled = []
        for (_, run) in work { run() }
    }

    func testShowingASurfaceReadsTheListAfterHalfASecondAndTwoSeconds() {
        let monitor = makeMonitor()
        monitor.surfaceShown()
        XCTAssertEqual(scheduled.map(\.0), [0.5, 2])
        XCTAssertTrue(lines.isEmpty, "nothing is read before the delays")
    }

    /// An unowned `NSWindow` is logged with its class name and level; a
    /// window with no `NSWindow` with a marker and the list's layer; the
    /// app's own window and a menu are not logged. The level is not an
    /// exclusion: a panel at the pop-up menu level is logged.
    func testUnownedAndUnmatchedWindowsAreLogged() {
        let own = makeWindow(NSWindow.self)
        let panel = makeWindow(ExampleInputPanel.self)
        panel.level = .popUpMenu
        windows = [1: own, 2: panel]
        list = [
            OnScreenWindowInfo(number: 1, width: 420, height: 640, layer: 0),
            OnScreenWindowInfo(number: 2, width: 320, height: 48, layer: 101),
            OnScreenWindowInfo(number: 3, width: 200, height: 30, layer: 101),
        ]
        let monitor = makeMonitor(ownWindow: own)
        monitor.surfaceShown()
        runScheduled()
        XCTAssertEqual(lines, [
            "window not created by the app shown: class=ExampleInputPanel size=320x48 level=101",
            "window not created by the app shown: class=<no NSWindow> size=200x30 level=101",
        ])
    }

    /// Once per showing: the second read logs nothing new; a window that
    /// left the list and came back is logged again.
    func testEachShowingIsLoggedOnce() {
        list = [OnScreenWindowInfo(number: 5, width: 200, height: 30, layer: 101)]
        let monitor = makeMonitor()
        monitor.surfaceShown()
        runScheduled()
        XCTAssertEqual(lines.count, 1, "both reads see the same window")

        list = []
        monitor.surfaceShown()
        runScheduled()
        list = [OnScreenWindowInfo(number: 5, width: 200, height: 30, layer: 101)]
        monitor.surfaceShown()
        runScheduled()
        XCTAssertEqual(lines.count, 2, "shown again after it was gone")
    }

    // MARK: - Window notifications

    /// A window the notification path sees: never ordered on screen; its
    /// shown state and number come from the test.
    private func notifiedWindow<W: NSWindow>(_ type: W.Type, number: Int) -> W {
        let window = makeWindow(type)
        assignedNumbers[ObjectIdentifier(window)] = number
        return window
    }

    private func show(_ window: NSWindow) {
        shown.insert(ObjectIdentifier(window))
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    private func hide(_ window: NSWindow) {
        shown.remove(ObjectIdentifier(window))
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    func testAShownUnownedWindowIsLoggedOnceWhileShown() {
        let monitor = makeMonitor()
        let panel = notifiedWindow(ExampleInputPanel.self, number: 21)
        show(panel)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("class=ExampleInputPanel"), lines[0])
        center.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        XCTAssertEqual(lines.count, 1, "not twice while shown")
        withExtendedLifetime(monitor) {}
    }

    func testAWindowIsLoggedAgainAfterItWasHiddenOrClosed() {
        let monitor = makeMonitor()
        let panel = notifiedWindow(ExampleInputPanel.self, number: 22)
        show(panel)
        hide(panel)
        show(panel)
        XCTAssertEqual(lines.count, 2, "shown again after hiding")
        center.post(name: NSWindow.willCloseNotification, object: panel)
        show(panel)
        XCTAssertEqual(lines.count, 3, "shown again after closing")
        withExtendedLifetime(monitor) {}
    }

    func testExcludedKindsAreNotLogged() {
        let own = notifiedWindow(NSWindow.self, number: 23)
        let monitor = makeMonitor(ownWindow: own)
        final class ExampleMenuWindow: NSPanel {}
        final class ExampleToolTipPanel: NSPanel {}
        final class ExamplePopoverWindow: NSPanel {}
        final class ExampleStatusBarWindow: NSPanel {}
        show(own)
        show(notifiedWindow(ExampleMenuWindow.self, number: 24))
        show(notifiedWindow(ExampleToolTipPanel.self, number: 25))
        show(notifiedWindow(ExamplePopoverWindow.self, number: 26))
        show(notifiedWindow(ExampleStatusBarWindow.self, number: 27))
        XCTAssertEqual(lines, [])
        withExtendedLifetime(monitor) {}
    }

    /// A window the list found first and the notifications then saw hidden
    /// counts as hidden: showing it again before the next list read logs
    /// it again.
    func testAWindowFoundByTheListAndHiddenByANotificationIsLoggedAgain() {
        let panel = notifiedWindow(ExampleInputPanel.self, number: 30)
        windows = [30: panel]
        list = [OnScreenWindowInfo(number: 30, width: 320, height: 48, layer: 101)]
        let monitor = makeMonitor()
        monitor.surfaceShown()
        scheduled.first?.1()
        XCTAssertEqual(lines.count, 1, "found by the list")
        hide(panel)
        show(panel)
        XCTAssertEqual(lines.count, 2, "hidden, then shown again")
    }
}
