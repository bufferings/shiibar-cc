import AppKit
import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The list's mouse tracking for the row drag (DESIGN.md §4.5 "row drag"):
/// the tracking stops when Core ends a drag while the button is still held
/// (the surface closed, the window lost key) and when the button is found
/// up without a release; only presses on a row of this list on screen
/// count; the drop line sits where the drop puts the row; the reason a row
/// cannot be dragged is placed at the pointer. The scroll view lives in a
/// window that is never ordered in (nothing reaches the screen), and the
/// mouse events are handed to the tracker directly. Every outward action is
/// a spy; the defaults are in memory.
@MainActor
final class ListDragTrackingTests: XCTestCase {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private var defaults = InMemoryDefaults()
    private var searches: [@MainActor (CLIRunResult) -> Void] = []
    private var indexCompletions: [@MainActor (Int32) -> Void] = []
    private var window: NSWindow?
    private var otherWindow: NSWindow?
    /// The mouse buttons the tracker reads as held.
    private var buttons = 1
    /// The tracker's clock, in seconds.
    private var clock: TimeInterval = 100

    override func tearDown() {
        window = nil
        otherWindow = nil
        super.tearDown()
    }

    private let height: CGFloat = 300

    private struct Tracker {
        let scroller: ListScroller
        let model: MainSurfaceModel
        let window: NSWindow
        let overlay: ListDragOverlay
        let scrollView: NSScrollView
    }

    /// Rows a and b; both starred unless `stars` says otherwise.
    private func makeTracker(stars: [String] = ["a", "b"]) throws -> Tracker {
        _ = NSApplication.shared
        defaults = InMemoryDefaults()
        defaults.set(stars, forKey: MainSurfaceDefaultsKeys.starredSessionList)
        buttons = 1
        clock = 100
        let model = MainSurfaceModel(
            home: "/Users/example", defaults: defaults, textSize: TextSizeStore(defaults: defaults),
            launchers: ConversationsLaunchers(
                search: { [weak self] _, _, completion in
                    self?.searches.append(completion)
                    return ConversationsProcess(process: Process())
                },
                show: { _, _, _ in ConversationsProcess(process: Process()) },
                index: { [weak self] _, _, _, completion in
                    self?.indexCompletions.append(completion)
                    return ConversationsProcess(process: Process())
                }),
            runCommand: { _, _ in },
            schedule: { _, _ in },
            markReadSchedule: { _, _ in })
        model.surfaceDidShow(.window)
        try XCTUnwrap(indexCompletions.last)(0)
        let json = ["a", "b"].map {
            #"{"session_id":"\#($0)","cwd":"/Users/example/demo","title":"t","updated_at":1,"live":false,"last_prompt":null}"#
        }
        try XCTUnwrap(searches.last)(CLIRunResult(
            exitCode: 0, stdout: #"{"conversations":[\#(json.joined(separator: ","))]}"#, stderr: ""))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        scrollView.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
        window.contentView = scrollView
        self.window = window
        XCTAssertFalse(window.isVisible, "never on screen")

        let overlay = ListDragOverlay()
        let scroller = ListScroller()
        scroller.attach(model: model, surface: .window, overlay: overlay)
        scroller.pressedMouseButtons = { [weak self] in self?.buttons ?? 0 }
        scroller.currentTime = { [weak self] in self?.clock ?? 0 }
        scroller.scrollViewChanged(scrollView)
        scroller.elementsChanged([
            ListElementExtent(kind: .heading(.starred), top: 8, bottom: 30, minX: 10, maxX: 390),
            ListElementExtent(kind: .row(.conversation(sessionID: "a")), top: 35, bottom: 100, minX: 11, maxX: 389),
            ListElementExtent(kind: .star(.conversation(sessionID: "a")), top: 44, bottom: 64, minX: 360, maxX: 380),
            ListElementExtent(kind: .row(.conversation(sessionID: "b")), top: 100, bottom: 165, minX: 11, maxX: 389),
        ])
        return Tracker(scroller: scroller, model: model, window: window, overlay: overlay, scrollView: scrollView)
    }

    /// A mouse event at a window point given with y growing downward from
    /// the window's top (the list content's coordinates while unscrolled).
    private func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: height - y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func startDrag(_ t: Tracker) throws {
        let down = try event(.leftMouseDown, x: 100, y: 50, in: t.window)
        XCTAssertTrue(down.window === t.window)
        t.scroller.handleMouse(down)
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 60, in: t.window))
        XCTAssertTrue(t.scroller.isTrackingDrag)
        XCTAssertEqual(t.model.list.cardDrag?.key, .conversation(sessionID: "a"))
    }

    // MARK: - The tracking ends with Core's drag

    func testTheAutoScrollTickStopsTheTrackingOnceCoreEndedTheDrag() throws {
        let t = try makeTracker()
        try startDrag(t)
        t.model.surfaceDidHide(.window)
        XCTAssertNil(t.model.list.cardDrag)
        t.scroller.autoScrollTick()
        XCTAssertFalse(t.scroller.isTrackingDrag)
    }

    func testTheTrackingStopsWhenTheSurfaceStopsBeingKey() throws {
        let t = try makeTracker()
        try startDrag(t)
        t.model.surfaceKeyChanged(surface: .window, isKey: false)
        XCTAssertNil(t.model.list.cardDrag)
        t.scroller.autoScrollTick()
        XCTAssertFalse(t.scroller.isTrackingDrag)
        XCTAssertEqual(t.model.list.stars, ["a", "b"])
    }

    func testAReleaseAfterTheSurfaceClosedEndsTheTrackingAndTheNextPressStartsClean() throws {
        let t = try makeTracker()
        try startDrag(t)
        t.model.surfaceDidHide(.window)
        t.scroller.handleMouse(try event(.leftMouseUp, x: 100, y: 140, in: t.window))
        XCTAssertFalse(t.scroller.isTrackingDrag)
        XCTAssertEqual(t.model.list.stars, ["a", "b"], "the cancelled drag changes nothing")

        t.model.surfaceDidShow(.window)
        try startDrag(t)
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 160, in: t.window))
        t.scroller.handleMouse(try event(.leftMouseUp, x: 100, y: 160, in: t.window))
        XCTAssertFalse(t.scroller.isTrackingDrag)
        XCTAssertNil(t.model.list.cardDrag)
        XCTAssertEqual(t.model.list.stars, ["b", "a"], "dropped on b's lower half: the end")
    }

    // MARK: - A release that never arrives (§4.5 "row drag": cancel)

    private var grace: TimeInterval { ListScroller.lostReleaseGraceSeconds }

    func testAButtonUpForTheGracePeriodWithoutAReleaseCancelsTheDrag() throws {
        let t = try makeTracker()
        try startDrag(t)
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 160, in: t.window))
        XCTAssertNotNil(t.model.list.cardDrag?.target)
        t.scroller.autoScrollTick()
        XCTAssertTrue(t.scroller.isTrackingDrag, "held: the drag goes on")
        buttons = 0
        t.scroller.autoScrollTick()
        XCTAssertTrue(t.scroller.isTrackingDrag, "the release may still be on its way")
        clock += grace / 2
        t.scroller.autoScrollTick()
        XCTAssertTrue(t.scroller.isTrackingDrag)
        clock += grace / 2
        t.scroller.autoScrollTick()
        XCTAssertFalse(t.scroller.isTrackingDrag)
        XCTAssertNil(t.model.list.cardDrag)
        XCTAssertEqual(t.model.list.stars, ["a", "b"], "no drop")
        XCTAssertEqual(t.model.list.selection?.key, .conversation(sessionID: "a"), "the start's selection stays")
    }

    func testAReleaseArrivingAfterTheButtonReadsUpStillDrops() throws {
        let t = try makeTracker()
        try startDrag(t)
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 160, in: t.window))
        buttons = 0
        t.scroller.autoScrollTick()
        clock += grace / 2
        t.scroller.autoScrollTick()
        t.scroller.handleMouse(try event(.leftMouseUp, x: 100, y: 160, in: t.window))
        XCTAssertFalse(t.scroller.isTrackingDrag)
        XCTAssertNil(t.model.list.cardDrag)
        XCTAssertEqual(t.model.list.stars, ["b", "a"], "dropped on b's lower half: the end")
    }

    func testTheGracePeriodStartsOverWhenTheButtonReadsDownAgain() throws {
        let t = try makeTracker()
        try startDrag(t)
        buttons = 0
        t.scroller.autoScrollTick()
        clock += grace / 2
        buttons = 1
        t.scroller.autoScrollTick()
        clock += grace / 2
        buttons = 0
        t.scroller.autoScrollTick()
        clock += grace / 2
        t.scroller.autoScrollTick()
        XCTAssertTrue(t.scroller.isTrackingDrag, "up since the later tick for half the grace period only")
        clock += grace / 2
        t.scroller.autoScrollTick()
        XCTAssertFalse(t.scroller.isTrackingDrag)
        XCTAssertEqual(t.model.list.stars, ["a", "b"])
    }

    /// While the button reads as up the list does not auto-scroll (§4.5
    /// "row drag": cancel); it scrolls again once the button reads as down.
    func testNoAutoScrollWhileTheButtonReadsUp() throws {
        let t = try makeTracker()
        try startDrag(t)
        // 10pt above the list's bottom edge: inside the auto-scroll zone.
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 290, in: t.window))
        func top() -> CGFloat { t.scrollView.contentView.bounds.minY }
        clock += 0.05
        t.scroller.autoScrollTick()
        let scrolled = top()
        XCTAssertGreaterThan(scrolled, 0, "held in the zone: the list scrolls down")

        buttons = 0
        clock += 0.05
        t.scroller.autoScrollTick()
        clock += grace / 2
        t.scroller.autoScrollTick()
        XCTAssertEqual(top(), scrolled, "no scrolling while the button reads up")
        XCTAssertTrue(t.scroller.isTrackingDrag, "within the grace period: not cancelled")

        buttons = 1
        clock += 0.05
        t.scroller.autoScrollTick()
        XCTAssertGreaterThan(top(), scrolled, "the button reads down again: scrolling resumes")
        XCTAssertTrue(t.scroller.isTrackingDrag)
    }

    func testAPressDuringADragCancelsItWithoutADrop() throws {
        let t = try makeTracker()
        try startDrag(t)
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 160, in: t.window))
        XCTAssertNotNil(t.model.list.cardDrag?.target)
        t.scroller.handleMouse(try event(.leftMouseDown, x: 100, y: 160, in: t.window))
        XCTAssertFalse(t.scroller.isTrackingDrag)
        XCTAssertNil(t.model.list.cardDrag)
        XCTAssertEqual(t.model.list.stars, ["a", "b"], "no drop")
    }

    // MARK: - Which presses count

    func testAPressOnTheStarStartsNoDrag() throws {
        let t = try makeTracker()
        t.scroller.handleMouse(try event(.leftMouseDown, x: 370, y: 50, in: t.window))
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 370, y: 60, in: t.window))
        XCTAssertFalse(t.scroller.isTrackingDrag)
        XCTAssertNil(t.model.list.cardDrag)
        XCTAssertNil(t.model.list.dragRefusal)
    }

    func testAPressWhileTheDetailPageCoversTheListStartsNoDrag() throws {
        let t = try makeTracker()
        t.model.windowColumnsChanged(.one)
        t.model.rowClicked(.conversation(sessionID: "a"))
        t.model.viewClicked()
        XCTAssertFalse(t.model.list.isListVisible)
        t.scroller.handleMouse(try event(.leftMouseDown, x: 100, y: 50, in: t.window))
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 60, in: t.window))
        XCTAssertFalse(t.scroller.isTrackingDrag)
        XCTAssertNil(t.model.list.cardDrag)
    }

    func testAPressInAnotherWindowStartsNoDrag() throws {
        let t = try makeTracker()
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        otherWindow = other
        t.scroller.handleMouse(try event(.leftMouseDown, x: 100, y: 50, in: other))
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 60, in: other))
        XCTAssertFalse(t.scroller.isTrackingDrag)
        XCTAssertNil(t.model.list.cardDrag)
    }

    // MARK: - Where things are drawn

    func testTheDropLineSitsOnTheBoundaryTheDropUses() throws {
        let t = try makeTracker()
        try startDrag(t)
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 110, in: t.window))
        XCTAssertEqual(t.model.list.cardDrag?.indicator, .line(before: "b"))
        XCTAssertEqual(t.scroller.dropLine(for: .line(before: "b")),
                       ListDragOverlay.Line(y: 100, minX: 7, maxX: 390), "b's top edge, from 3pt left of the frame")
        XCTAssertEqual(t.scroller.dropLine(for: .line(before: nil))?.y, 165, "the last row's bottom edge")
        XCTAssertNil(t.scroller.dropLine(for: .heading(.recent)))
        t.scroller.handleMouse(try event(.leftMouseUp, x: 100, y: 110, in: t.window))
        XCTAssertEqual(t.model.list.stars, ["a", "b"], "dropped right above b: where it was")
    }

    func testAPointerOutsideTheListOnEitherSideHasNoTarget() throws {
        let t = try makeTracker()
        try startDrag(t)
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 5, y: 110, in: t.window))
        XCTAssertNotNil(t.model.list.cardDrag?.target, "the side margin counts as the row at that height")
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 420, y: 110, in: t.window))
        XCTAssertNil(t.model.list.cardDrag?.target, "right of the list")
        t.scroller.handleMouse(try event(.leftMouseDragged, x: -20, y: 110, in: t.window))
        XCTAssertNil(t.model.list.cardDrag?.target, "left of the list")
    }

    func testTheFloatingImageAndTheReasonFollowTheVisibleTopLeft() throws {
        let t = try makeTracker(stars: [])
        // Scrolled by 100: a window point 60 below the top is content 160.
        t.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        t.scrollView.reflectScrolledClipView(t.scrollView.contentView)
        t.scroller.handleMouse(try event(.leftMouseDown, x: 100, y: 20, in: t.window))
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 30, in: t.window))
        XCTAssertNil(t.model.list.cardDrag, "a Recent row without Starred rows")
        XCTAssertEqual(t.model.list.dragRefusal?.text, "Click the star to add it to Starred")
        XCTAssertEqual(t.overlay.tip, CGPoint(x: 100, y: 30), "where the pointer is, from the list's visible top-left")
        t.scroller.handleMouse(try event(.leftMouseDragged, x: 140, y: 80, in: t.window))
        XCTAssertEqual(t.overlay.tip, CGPoint(x: 100, y: 30), "it does not follow the pointer")
        t.scroller.handleMouse(try event(.leftMouseUp, x: 140, y: 80, in: t.window))

        let dragging = try makeTracker()
        dragging.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 20))
        dragging.scrollView.reflectScrolledClipView(dragging.scrollView.contentView)
        dragging.scroller.handleMouse(try event(.leftMouseDown, x: 100, y: 30, in: dragging.window))
        dragging.scroller.handleMouse(try event(.leftMouseDragged, x: 100, y: 40, in: dragging.window))
        XCTAssertEqual(dragging.model.list.cardDrag?.key, .conversation(sessionID: "a"))
        XCTAssertEqual(dragging.overlay.ghost?.pointer, CGPoint(x: 100, y: 40))
        XCTAssertEqual(dragging.overlay.ghost?.grab, CGPoint(x: 89, y: 15), "the press on the row: content 50, row top 35")
    }
}
