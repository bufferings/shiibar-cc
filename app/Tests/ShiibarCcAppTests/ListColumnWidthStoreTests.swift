import AppKit
import Combine
import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The remembered two-column list column width and the boundary drag area
/// (DESIGN.md §4.5 "column boundary drag", §8.53, §9). In-memory defaults
/// only: nothing reaches `UserDefaults.standard`. No window is shown.
@MainActor
final class ListColumnWidthStoreTests: XCTestCase {
    private var defaults = InMemoryDefaults()

    override func setUp() {
        super.setUp()
        defaults = InMemoryDefaults()
    }

    private var stored: Any? { defaults.object(forKey: MainSurfaceDefaultsKeys.listColumnWidth) }

    // MARK: - Loading

    func testLoadingInterpretsTheStoredValueWithoutRewritingIt() {
        let cases: [(String, Any?, Double?)] = [
            ("missing", nil, nil),
            ("width", 512.0, 512),
            ("below the minimum", 279.0, 279),
            ("zero", 0.0, nil),
            ("negative", -3.0, nil),
            ("string", "512", nil),
        ]
        for (name, value, expected) in cases {
            defaults = InMemoryDefaults()
            defaults.set(value, forKey: MainSurfaceDefaultsKeys.listColumnWidth)
            let store = ListColumnWidthStore(defaults: defaults)
            XCTAssertEqual(store.remembered, expected, name)
            XCTAssertEqual(stored as? NSObject, value as? NSObject, "\(name): the stored entry is not rewritten")
        }
    }

    func testRememberedBelowTheMinimumIsShownAtTheMinimum() {
        defaults.set(279.0, forKey: MainSurfaceDefaultsKeys.listColumnWidth)
        let store = ListColumnWidthStore(defaults: defaults)
        XCTAssertEqual(store.shownWidth(windowWidth: 1400, textSize: .default), 280)
        XCTAssertEqual(stored as? Double, 279)
    }

    // MARK: - Drag

    func testDragEndPersistsTheRoundedWidth() {
        let store = ListColumnWidthStore(defaults: defaults)
        store.beginDrag(windowWidth: 1400, textSize: .default)
        store.updateDrag(delta: 50.4, windowWidth: 1400)
        XCTAssertEqual(store.shownWidth(windowWidth: 1400, textSize: .default), 470.4, "follows the pointer while dragging")
        XCTAssertNil(stored, "nothing is stored before mouse-up")
        store.endDrag()
        XCTAssertEqual(stored as? Double, 470)
        XCTAssertEqual(store.remembered, 470)
        XCTAssertNil(store.drag)
        XCTAssertEqual(store.shownWidth(windowWidth: 1400, textSize: .default), 470)
    }

    func testClickWithoutMovementStoresNothing() {
        let store = ListColumnWidthStore(defaults: defaults)
        store.beginDrag(windowWidth: 1400, textSize: .default)
        store.endDrag()
        XCTAssertNil(stored)
        XCTAssertNil(store.remembered)

        // A click on a column shown clamped keeps the remembered value.
        defaults.set(700.0, forKey: MainSurfaceDefaultsKeys.listColumnWidth)
        let clamped = ListColumnWidthStore(defaults: defaults)
        clamped.beginDrag(windowWidth: 1000, textSize: .default)
        clamped.endDrag()
        XCTAssertEqual(stored as? Double, 700)
        XCTAssertEqual(clamped.shownWidth(windowWidth: 1400, textSize: .default), 700)
    }

    func testDragBackToTheStartStoresNothing() {
        let store = ListColumnWidthStore(defaults: defaults)
        store.beginDrag(windowWidth: 1400, textSize: .default)
        store.updateDrag(delta: 80, windowWidth: 1400)
        store.updateDrag(delta: 0, windowWidth: 1400)
        store.endDrag()
        XCTAssertNil(stored)
    }

    func testLeavingTwoColumnsDuringADragStoresNothing() {
        let model = makeModel()
        let store = model.listColumnWidth
        model.windowWidthChanged(1400)
        store.beginDrag(windowWidth: 1400, textSize: model.textSize.size)
        store.updateDrag(delta: 60, windowWidth: 1400)
        // An 800pt window is two columns at 13 (threshold 780) and one at 14
        // (threshold 812): ⌘= ends the drag.
        model.windowWidthChanged(800)
        model.textSize.increase()
        XCTAssertEqual(ColumnMode.forWindowWidth(800, textSize: model.textSize.size), .one)
        XCTAssertNil(store.drag, "the drag ends")
        store.endDrag()
        XCTAssertNil(stored, "nothing is remembered")
    }

    func testHidingTheWindowDuringADragStoresNothing() {
        let model = makeModel()
        let store = model.listColumnWidth
        model.surfaceDidShow(.window)
        model.windowWidthChanged(1400)
        store.beginDrag(windowWidth: 1400, textSize: model.textSize.size)
        store.updateDrag(delta: 60, windowWidth: 1400)
        model.surfaceDidHide(.window)
        XCTAssertNil(store.drag, "the drag ends")
        store.endDrag()
        XCTAssertNil(stored, "nothing is remembered")
        XCTAssertEqual(store.shownWidth(windowWidth: 1400, textSize: model.textSize.size), 420)
    }

    func testDragWidthIsClampedToTheCurrentWindowWidth() {
        let store = ListColumnWidthStore(defaults: defaults)
        store.beginDrag(windowWidth: 1400, textSize: .default)
        store.updateDrag(delta: 400, windowWidth: 1400)
        XCTAssertEqual(store.shownWidth(windowWidth: 1400, textSize: .default), 820)
        // The window narrows with no pointer move: the right column keeps
        // its minimum.
        XCTAssertEqual(store.shownWidth(windowWidth: 1000, textSize: .default), 640)
    }

    // MARK: - Double click

    func testDoubleClickErasesTheRememberedWidth() {
        defaults.set(600.0, forKey: MainSurfaceDefaultsKeys.listColumnWidth)
        let store = ListColumnWidthStore(defaults: defaults)
        XCTAssertEqual(store.shownWidth(windowWidth: 1400, textSize: .default), 600)
        store.resetToDefault()
        XCTAssertNil(stored)
        XCTAssertNil(store.remembered)
        XCTAssertEqual(store.shownWidth(windowWidth: 1400, textSize: .default), 420)
    }

    func testDoubleClickWithNothingRememberedChangesNothing() {
        let store = ListColumnWidthStore(defaults: defaults)
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        store.resetToDefault()
        subscription.cancel()
        XCTAssertEqual(changes, 0)
        XCTAssertNil(stored)
        XCTAssertNil(store.remembered)
    }

    // MARK: - Text size

    func testTextSizeChangeKeepsARememberedWidth() {
        defaults.set(500.0, forKey: MainSurfaceDefaultsKeys.listColumnWidth)
        let model = makeModel()
        let store = model.listColumnWidth
        XCTAssertEqual(store.shownWidth(windowWidth: 1600, textSize: model.textSize.size), 500)
        model.textSize.increase()
        model.textSize.increase()
        XCTAssertEqual(store.shownWidth(windowWidth: 1600, textSize: model.textSize.size), 500)
        model.textSize.reset()
        XCTAssertEqual(store.shownWidth(windowWidth: 1600, textSize: model.textSize.size), 500)
        XCTAssertEqual(stored as? Double, 500)
    }

    func testTextSizeChangeMovesTheDefaultWidth() {
        let model = makeModel()
        let store = model.listColumnWidth
        XCTAssertEqual(store.shownWidth(windowWidth: 1600, textSize: model.textSize.size), 420)
        model.textSize.apply(TextSize(clamping: 18))
        XCTAssertEqual(store.shownWidth(windowWidth: 1600, textSize: model.textSize.size), TextSize(clamping: 18).listColumnWidth)
        XCTAssertNil(stored)
    }

    // MARK: - Drag area view

    private func mouseEvent(_ type: NSEvent.EventType, clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
    }

    func testDragViewNeverMovesTheWindow() {
        let view = ColumnBoundaryDragView()
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testDragViewReportsScreenTravel() {
        let view = ColumnBoundaryDragView()
        var pointerX: CGFloat = 100
        view.pointerLocation = { NSPoint(x: pointerX, y: 0) }
        var log: [String] = []
        view.onBegin = { log.append("begin") }
        view.onDrag = { log.append("drag \($0)") }
        view.onEnd = { log.append("end") }
        view.onDoubleClick = { log.append("double") }

        view.mouseDown(with: mouseEvent(.leftMouseDown, clickCount: 1))
        pointerX = 130
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, clickCount: 1))
        pointerX = 70
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, clickCount: 1))
        view.mouseUp(with: mouseEvent(.leftMouseUp, clickCount: 1))
        XCTAssertEqual(log, ["begin", "drag 30.0", "drag -30.0", "end"])
    }

    func testDragViewDoubleClickResetsWithoutADrag() {
        let view = ColumnBoundaryDragView()
        view.pointerLocation = { .zero }
        var log: [String] = []
        view.onBegin = { log.append("begin") }
        view.onDrag = { _ in log.append("drag") }
        view.onEnd = { log.append("end") }
        view.onDoubleClick = { log.append("double") }

        view.mouseDown(with: mouseEvent(.leftMouseDown, clickCount: 1))
        view.mouseUp(with: mouseEvent(.leftMouseUp, clickCount: 1))
        view.mouseDown(with: mouseEvent(.leftMouseDown, clickCount: 2))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, clickCount: 2))
        view.mouseUp(with: mouseEvent(.leftMouseUp, clickCount: 2))
        XCTAssertEqual(log, ["begin", "end", "double"])
    }

    func testDragViewRemovedFromItsWindowCancelsTheDrag() {
        let view = ColumnBoundaryDragView()
        view.pointerLocation = { .zero }
        var log: [String] = []
        view.onBegin = { log.append("begin") }
        view.onEnd = { log.append("end") }
        view.onCancel = { log.append("cancel") }

        // Not dragging: nothing happens.
        view.viewDidMoveToWindow()
        view.mouseDown(with: mouseEvent(.leftMouseDown, clickCount: 1))
        // The view is in no window, as after the window closes.
        view.viewDidMoveToWindow()
        view.mouseUp(with: mouseEvent(.leftMouseUp, clickCount: 1))
        XCTAssertEqual(log, ["begin", "cancel"])
        XCTAssertFalse(view.isDragging)
    }

    func testFirstClickOfADoubleClickKeepsTheWidth() {
        // The first click is a drag without movement; the second resets.
        let store = ListColumnWidthStore(defaults: defaults)
        store.beginDrag(windowWidth: 1400, textSize: .default)
        XCTAssertEqual(store.shownWidth(windowWidth: 1400, textSize: .default), 420)
        store.endDrag()
        XCTAssertEqual(store.shownWidth(windowWidth: 1400, textSize: .default), 420)
        XCTAssertNil(stored)
    }

    // MARK: - Helpers

    private func makeModel() -> MainSurfaceModel {
        let launchers = ConversationsLaunchers(
            search: { _, _, _ in ConversationsProcess(process: Process()) },
            show: { _, _, _ in ConversationsProcess(process: Process()) },
            index: { _, _, _, _ in ConversationsProcess(process: Process()) }
        )
        return MainSurfaceModel(
            home: "/Users/example",
            defaults: defaults,
            textSize: TextSizeStore(defaults: defaults),
            launchers: launchers,
            runCommand: { _, _ in },
            schedule: { _, _ in }
        )
    }
}
