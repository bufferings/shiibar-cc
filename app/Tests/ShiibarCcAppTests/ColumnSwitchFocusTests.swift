import AppKit
import ShiibarCcCore
import SwiftUI
import XCTest
@testable import ShiibarCcApp

/// The key target across a change of the window's column count (DESIGN.md
/// §4.5 "switching by width" / "when the width changes", "key operations"),
/// and Tab / Shift-Tab while the one-column detail page covers the list
/// page: the main surface view is hosted in a window the way the app hosts
/// it, and the window is resized across the two-column width. The window is
/// ordered in at an offscreen position without activating the app or
/// becoming key: a focus request reaches the search field only in a
/// visible window, so a hidden window would not show a focus move. Every
/// outward action is a spy — no subprocess, state dir, or
/// `UserDefaults.standard`.
@MainActor
final class ColumnSwitchFocusTests: XCTestCase {
    /// Keeps the frame given to it: AppKit would move a window placed
    /// outside every screen back onto one.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private var defaults = InMemoryDefaults()
    private var window: NSWindow?
    private var focusObservation: NSKeyValueObservation?
    private var searches: [@MainActor (CLIRunResult) -> Void] = []
    private var indexCompletions: [@MainActor (Int32) -> Void] = []

    private let height: CGFloat = 640
    private var oneColumnWidth: CGFloat { CGFloat(MainWindowMetrics.initialWidth) }
    private var twoColumnWidth: CGFloat { CGFloat(TextSize.default.twoColumnMinimumWidth) + 200 }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        defaults = InMemoryDefaults()
        searches = []
        indexCompletions = []
    }

    override func tearDown() {
        focusObservation = nil
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    // MARK: - Harness

    /// Runs the main run loop (SwiftUI updates and the main-queue blocks
    /// they schedule) until `condition` holds, then once more, so a block
    /// queued by the last update has run too.
    private func pump(until condition: () -> Bool = { true }, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func makeModel() -> MainSurfaceModel {
        let launchers = ConversationsLaunchers(
            search: { [weak self] _, _, completion in
                self?.searches.append(completion)
                return ConversationsProcess(process: Process())
            },
            show: { _, _, _ in ConversationsProcess(process: Process()) },
            index: { [weak self] _, _, _, completion in
                self?.indexCompletions.append(completion)
                return ConversationsProcess(process: Process())
            }
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

    /// The window as `MainSurfaceController.openWindow` sets it up: the
    /// same content view, the window shown, the initial focus request (the
    /// search field on the list page), and the conversations delivered
    /// (one by default).
    private func openWindow(width: CGFloat, conversations: [String] = ["s1"]) throws -> (MainSurfaceModel, NSWindow) {
        let model = makeModel()
        let window = OffscreenWindow(
            contentRect: NSRect(x: -40000, y: -40000, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        let hosting = FirstMouseHostingView(rootView: MainSurfaceView(model: model, textSize: model.textSize, surface: .window))
        return try show(hosting, in: window, surface: .window, model: model, conversations: conversations)
    }

    /// The popover's content (always one column), hosted in a plain
    /// borderless offscreen window as the popover hosts it.
    private func openPopoverContent(conversations: [String] = ["s1"]) throws -> (MainSurfaceModel, NSWindow) {
        let model = makeModel()
        let window = OffscreenWindow(
            contentRect: NSRect(x: -40000, y: -40000, width: CGFloat(TextSize.default.popoverWidth), height: height),
            styleMask: [.borderless], backing: .buffered, defer: true)
        let hosting = NSHostingView(rootView: MainSurfaceView(model: model, textSize: model.textSize, surface: .popover))
        return try show(hosting, in: window, surface: .popover, model: model, conversations: conversations)
    }

    private func show(
        _ hosting: NSHostingView<MainSurfaceView>, in window: NSWindow, surface: MainSurface, model: MainSurfaceModel,
        conversations: [String]
    ) throws -> (MainSurfaceModel, NSWindow) {
        // ARC holds the reference (release-on-close double-frees under XCTest).
        window.isReleasedWhenClosed = false
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        self.window = window
        observeFocus(of: window, surface: surface, model: model)
        model.surfaceDidShow(surface)
        window.orderFrontRegardless()
        model.requestInitialFocus()
        pump(until: { MainSurfaceController.isSearchFieldFocused(in: window) })
        XCTAssertLessThan(window.frame.maxX, -30000, "the window must stay offscreen")
        XCTAssertTrue(MainSurfaceController.isSearchFieldFocused(in: window), "the surface opens with the search field focused")
        try XCTUnwrap(indexCompletions.last)(0)
        let json = conversations.enumerated().map { index, id in
            #"{"session_id":"\#(id)","cwd":"/Users/example/demo","title":"t","updated_at":\#(100 - index),"live":false,"last_prompt":null}"#
        }
        try XCTUnwrap(searches.last)(CLIRunResult(
            exitCode: 0, stdout: #"{"conversations":[\#(json.joined(separator: ","))]}"#, stderr: ""))
        pump()
        return (model, window)
    }

    /// Reports the search field's focus to the model on every first
    /// responder change, settled a tick later, as `MainSurfaceController`
    /// does: the bottom panel's buttons follow the report (§8.55).
    private func observeFocus(of window: NSWindow, surface: MainSurface, model: MainSurfaceModel) {
        focusObservation = window.observe(\.firstResponder) { window, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    model.searchFieldFocusChanged(
                        surface: surface, focused: MainSurfaceController.isSearchFieldFocused(in: window))
                }
            }
        }
    }

    private func resize(_ window: NSWindow, model: MainSurfaceModel, to width: CGFloat, expecting columns: ColumnMode) {
        window.setContentSize(NSSize(width: width, height: height))
        pump(until: { model.list.columns == columns })
        XCTAssertEqual(model.list.columns, columns)
    }

    /// The list has focus: the window itself is the first responder
    /// (`MainSurfaceController.focusList`), with a row selected.
    private func focusListWithSelectedRow(_ model: MainSurfaceModel, in window: NSWindow) {
        window.makeFirstResponder(nil)
        model.rowClicked(.conversation(sessionID: "s1"))
        pump()
        XCTAssertNotNil(model.list.selection)
        XCTAssertTrue(window.firstResponder === window)
    }

    private func searchField(in window: NSWindow) throws -> SearchTextField {
        try XCTUnwrap(Self.find(SearchTextField.self, in: try XCTUnwrap(window.contentView)))
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    /// The conversation pane has focus: its web view, in this window, is
    /// the first responder.
    private func focusPane(_ model: MainSurfaceModel, in window: NSWindow) {
        let webView = model.webPane.webView
        pump(until: { webView.window === window })
        XCTAssertTrue(webView.window === window, "the pane's web view is in the window")
        window.makeFirstResponder(webView)
        pump()
        XCTAssertTrue(MainSurfaceController.responder(window.firstResponder, isInside: webView))
    }

    // MARK: - List focus

    func testListFocusInOneColumnStaysOnTheListWhenTheWindowWidensAndNarrows() throws {
        let (model, window) = try openWindow(width: oneColumnWidth)
        XCTAssertEqual(model.list.columns, .one)
        let field = try searchField(in: window)
        focusListWithSelectedRow(model, in: window)

        resize(window, model: model, to: twoColumnWidth, expecting: .two)
        XCTAssertTrue(window.firstResponder === window, "the list keeps focus in two columns")
        XCTAssertNotNil(model.list.selection)

        resize(window, model: model, to: oneColumnWidth, expecting: .one)
        XCTAssertTrue(window.firstResponder === window, "the list keeps focus back in one column")
        XCTAssertNotNil(model.list.selection)
        XCTAssertTrue(try searchField(in: window) === field, "the search field is the same view in both column modes")
    }

    func testListFocusInTwoColumnsStaysOnTheListWhenTheWindowNarrowsAndWidens() throws {
        let (model, window) = try openWindow(width: twoColumnWidth)
        XCTAssertEqual(model.list.columns, .two)
        focusListWithSelectedRow(model, in: window)

        resize(window, model: model, to: oneColumnWidth, expecting: .one)
        XCTAssertTrue(window.firstResponder === window, "the list keeps focus in one column")
        XCTAssertNotNil(model.list.selection)

        resize(window, model: model, to: twoColumnWidth, expecting: .two)
        XCTAssertTrue(window.firstResponder === window, "the list keeps focus back in two columns")
        XCTAssertNotNil(model.list.selection)
    }

    // MARK: - Sections and the row drag keep the list page

    /// A drag of a row onto `hit` and its drop, with the pumps between.
    private func dragAndDrop(_ model: MainSurfaceModel, surface: MainSurface, row: String, onto hit: ListPointerHit) {
        model.pointerDown(surface: surface, surfaceWasKey: true, searchFieldFocused: false, clickCount: 1)
        model.rowPressed(.conversation(sessionID: row), clickCount: 1, onStar: false, x: 10, y: 10)
        model.rowPressDragged(x: 10, y: 20)
        pump()
        XCTAssertNotNil(model.list.cardDrag, "\(surface)")
        model.cardDragMoved(hit)
        pump()
        model.cardDragEnded()
        pump()
    }

    private func clickHeading(_ model: MainSurfaceModel, surface: MainSurface, _ heading: ListHeading) {
        model.pointerDown(surface: surface, surfaceWasKey: true, searchFieldFocused: false, clickCount: 1)
        model.headingClicked(heading)
        pump()
    }

    /// §4.5 "collapsing sections" / "row drag": adding the Starred section,
    /// closing and opening headings, and drops that move rows keep the same
    /// search field. A search field built anew would run the surface's
    /// earlier focus request again and take the focus (DESIGN.md §8.59).
    func testSectionChangesAndDropsKeepTheSearchField() throws {
        for surface in [MainSurface.window, .popover] {
            let conversations = ["s1", "s2", "s3"]
            let (model, window) = surface == .window
                ? try openWindow(width: oneColumnWidth, conversations: conversations)
                : try openPopoverContent(conversations: conversations)
            let field = try searchField(in: window)
            window.makeFirstResponder(nil)
            pump()

            model.starClicked(sessionID: "s1")
            model.starClicked(sessionID: "s2")
            pump()
            XCTAssertEqual(model.list.headings.map(\.heading), [.history, .starred, .recent], "\(surface)")
            clickHeading(model, surface: surface, .starred)
            XCTAssertEqual(model.list.headings.map(\.isOpen), [true, false, true], "\(surface)")
            clickHeading(model, surface: surface, .history)
            clickHeading(model, surface: surface, .history)
            clickHeading(model, surface: surface, .starred)

            // A reorder inside Starred, then a Recent row starred at a place.
            dragAndDrop(model, surface: surface, row: "s2", onto: .element(.row(.conversation(sessionID: "s1")), upperHalf: true))
            XCTAssertEqual(model.list.starredRows.map(\.sessionID), ["s2", "s1"], "\(surface)")
            dragAndDrop(model, surface: surface, row: "s3", onto: .element(.row(.conversation(sessionID: "s2")), upperHalf: false))
            XCTAssertEqual(model.list.starredRows.map(\.sessionID), ["s2", "s3", "s1"], "\(surface)")
            XCTAssertEqual(model.list.headings.map(\.heading), [.history, .starred], "\(surface)")

            XCTAssertTrue(try searchField(in: window) === field, "\(surface): the search field is not built anew")
            XCTAssertFalse(MainSurfaceController.isSearchFieldFocused(in: window),
                           "\(surface): no earlier focus request runs again")
            window.orderOut(nil)
            defaults = InMemoryDefaults()
        }
    }

    /// §4.5 "collapsing sections": a heading click on a window that is not
    /// key asks it to become key without moving its first responder and
    /// without activating the app. (Whether it becomes key cannot be seen
    /// here: an app that is not active has no key window, and the test must
    /// not activate it.)
    func testMakingTheSurfaceKeyKeepsItsFirstResponder() throws {
        let (_, window) = try openWindow(width: oneColumnWidth)
        let other = OffscreenWindow(
            contentRect: NSRect(x: -42000, y: -42000, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        other.orderFrontRegardless()
        other.makeKey()
        pump()
        let responder = window.firstResponder
        let wasActive = NSApp.isActive
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(MainSurfaceController.isSearchFieldFocused(in: window))
        MainSurfaceController.makeKeyKeepingFocus(window)
        pump()
        XCTAssertTrue(window.firstResponder === responder, "the focus stays where it was")
        XCTAssertEqual(NSApp.isActive, wasActive, "the app is not activated")
        other.orderOut(nil)
    }

    // MARK: - Search field focus

    func testSearchFieldFocusKeepsItsTextAndCaretAcrossColumnChanges() throws {
        let (model, window) = try openWindow(width: oneColumnWidth)
        model.query = "abc"
        pump()
        let field = try searchField(in: window)
        XCTAssertEqual(field.stringValue, "abc")
        XCTAssertTrue(MainSurfaceController.isSearchFieldFocused(in: window))
        let caret = NSRange(location: 1, length: 0)
        try XCTUnwrap(field.currentEditor()).selectedRange = caret

        resize(window, model: model, to: twoColumnWidth, expecting: .two)
        XCTAssertTrue(MainSurfaceController.isSearchFieldFocused(in: window), "the search field keeps focus in two columns")
        XCTAssertEqual(field.stringValue, "abc")
        XCTAssertEqual(field.currentEditor()?.selectedRange, caret)

        resize(window, model: model, to: oneColumnWidth, expecting: .one)
        XCTAssertTrue(MainSurfaceController.isSearchFieldFocused(in: window), "the search field keeps focus back in one column")
        XCTAssertEqual(field.stringValue, "abc")
        XCTAssertEqual(field.currentEditor()?.selectedRange, caret)
        XCTAssertEqual(model.query, "abc")
    }

    // MARK: - Conversation pane focus

    func testPaneFocusOnTheOneColumnDetailPageDoesNotMoveToTheSearchFieldWhenTheWindowWidens() throws {
        let (model, window) = try openWindow(width: oneColumnWidth)
        focusListWithSelectedRow(model, in: window)
        model.viewClicked()
        pump()
        XCTAssertEqual(model.list.page, .detail)
        focusPane(model, in: window)

        resize(window, model: model, to: twoColumnWidth, expecting: .two)
        XCTAssertFalse(MainSurfaceController.isSearchFieldFocused(in: window), "the search field does not take focus")
    }

    func testPaneFocusInTwoColumnsDoesNotMoveToTheSearchFieldWhenTheWindowNarrows() throws {
        let (model, window) = try openWindow(width: twoColumnWidth)
        focusListWithSelectedRow(model, in: window)
        focusPane(model, in: window)

        resize(window, model: model, to: oneColumnWidth, expecting: .one)
        XCTAssertFalse(MainSurfaceController.isSearchFieldFocused(in: window), "the search field does not take focus")
    }

    // MARK: - Focus requests after a column change

    func testCommandFAfterAColumnChangeFocusesTheSearchFieldWithTheCaretAtTheEnd() throws {
        // ⌘F (§4.5 "key operations"): the request reaches the field in the
        // new layout, with the caret at the end of the kept text.
        let (model, window) = try openWindow(width: oneColumnWidth)
        model.query = "abc"
        focusListWithSelectedRow(model, in: window)
        resize(window, model: model, to: twoColumnWidth, expecting: .two)
        XCTAssertTrue(window.firstResponder === window)

        _ = model.handleKey(key: .other(charactersIgnoringModifiers: "f"), modifiers: [.command], surface: .window,
                            hasMarkedText: false, searchFieldFocused: false)
        pump(until: { MainSurfaceController.isSearchFieldFocused(in: window) })
        XCTAssertTrue(MainSurfaceController.isSearchFieldFocused(in: window))
        XCTAssertEqual(try searchField(in: window).currentEditor()?.selectedRange, NSRange(location: 3, length: 0))
    }

    func testThePopoversContentFocusesTheSearchFieldWhenItOpensOnTheListPage() throws {
        // §4.5 "popover": opening on the list page focuses the search field.
        let (_, window) = try openPopoverContent()
        XCTAssertTrue(MainSurfaceController.isSearchFieldFocused(in: window))
    }

    // MARK: - Tab on the one-column detail page (§4.5 "key operations")

    /// Opens the selected row's detail page with the conversation pane
    /// focused, as View does.
    private func openDetailPageWithPaneFocused(_ model: MainSurfaceModel, in window: NSWindow) {
        focusListWithSelectedRow(model, in: window)
        model.viewClicked()
        pump()
        XCTAssertEqual(model.list.page, .detail)
        focusPane(model, in: window)
        XCTAssertNotNil(detailBottomPanelButtons(model), "the detail page shows the buttons")
    }

    private func detailBottomPanelButtons(_ model: MainSurfaceModel) -> BottomPanelButtons? {
        guard case .conversation(let pane) = model.list.paneContent else { return nil }
        return pane.bottomPanel.buttons
    }

    /// A Tab (or Shift-Tab) key press delivered to the window, as AppKit
    /// delivers a typed key to the first responder.
    private func pressTab(in window: NSWindow, shift: Bool) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: shift ? "\u{19}" : "\t", charactersIgnoringModifiers: shift ? "\u{19}" : "\t",
            isARepeat: false, keyCode: 48))
        window.sendEvent(event)
        pump()
    }

    /// Whether a run of key view steps (the window's own Tab traversal),
    /// starting from the current first responder, focuses the search field.
    private func keyViewStepsReachTheSearchField(in window: NSWindow, count: Int, backward: Bool) -> Bool {
        var reached = false
        for _ in 0..<count {
            if backward {
                window.selectPreviousKeyView(nil)
            } else {
                window.selectNextKeyView(nil)
            }
            reached = reached || MainSurfaceController.isSearchFieldFocused(in: window)
        }
        return reached
    }

    private func assertTabNeverReachesTheSearchField(
        _ model: MainSurfaceModel, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for shift in [false, true] {
            focusPane(model, in: window)
            for _ in 0..<4 {
                try pressTab(in: window, shift: shift)
                XCTAssertFalse(MainSurfaceController.isSearchFieldFocused(in: window),
                               "a typed \(shift ? "Shift-Tab" : "Tab") skips the hidden search field", file: file, line: line)
            }
            focusPane(model, in: window)
            XCTAssertFalse(keyViewStepsReachTheSearchField(in: window, count: 6, backward: shift),
                           "the key view loop skips the hidden search field (\(shift ? "backward" : "forward"))",
                           file: file, line: line)
        }
        pump()
        XCTAssertFalse(model.list.isSearchFieldFocused, "the model does not see search field focus", file: file, line: line)
        XCTAssertEqual(model.list.page, .detail, file: file, line: line)
        XCTAssertNotNil(detailBottomPanelButtons(model), "the buttons stay shown", file: file, line: line)
    }

    /// Back on the list page the field takes focus again: by ⌘F, and by a
    /// Tab from the list (the window as first responder).
    private func assertTheSearchFieldTakesFocusAfterGoingBack(
        _ model: MainSurfaceModel, in window: NSWindow, surface: MainSurface,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        model.backClicked()
        pump(until: { model.list.page == .list })
        XCTAssertEqual(model.list.page, .list, file: file, line: line)

        window.makeFirstResponder(nil)
        pump()
        XCTAssertTrue(keyViewStepsReachTheSearchField(in: window, count: 6, backward: false),
                      "Tab reaches the search field on the list page", file: file, line: line)

        window.makeFirstResponder(nil)
        pump()
        XCTAssertFalse(MainSurfaceController.isSearchFieldFocused(in: window), file: file, line: line)
        _ = model.handleKey(key: .other(charactersIgnoringModifiers: "f"), modifiers: [.command], surface: surface,
                            hasMarkedText: false, searchFieldFocused: false)
        pump(until: { MainSurfaceController.isSearchFieldFocused(in: window) })
        XCTAssertTrue(MainSurfaceController.isSearchFieldFocused(in: window), "⌘F focuses the search field",
                      file: file, line: line)
        pump(until: { model.list.isSearchFieldFocused })
        XCTAssertTrue(model.list.isSearchFieldFocused, file: file, line: line)
    }

    func testTabOnTheWindowsDetailPageNeverFocusesTheHiddenSearchField() throws {
        let (model, window) = try openWindow(width: oneColumnWidth)
        let field = try searchField(in: window)
        openDetailPageWithPaneFocused(model, in: window)
        try assertTabNeverReachesTheSearchField(model, in: window)
        try assertTheSearchFieldTakesFocusAfterGoingBack(model, in: window, surface: .window)
        XCTAssertTrue(try searchField(in: window) === field, "the list page is not built anew")
    }

    func testTabOnThePopoversDetailPageNeverFocusesTheHiddenSearchField() throws {
        let (model, window) = try openPopoverContent()
        let field = try searchField(in: window)
        openDetailPageWithPaneFocused(model, in: window)
        try assertTabNeverReachesTheSearchField(model, in: window)
        try assertTheSearchFieldTakesFocusAfterGoingBack(model, in: window, surface: .popover)
        XCTAssertTrue(try searchField(in: window) === field, "the list page is not built anew")
    }

    func testTabFromThePaneReachesTheSearchFieldInTwoColumns() throws {
        // Two columns show the list column beside the pane: the search
        // field stays a Tab target.
        let (model, window) = try openWindow(width: twoColumnWidth)
        focusListWithSelectedRow(model, in: window)
        focusPane(model, in: window)
        XCTAssertTrue(keyViewStepsReachTheSearchField(in: window, count: 6, backward: false),
                      "Tab reaches the search field")
        focusPane(model, in: window)
        XCTAssertTrue(keyViewStepsReachTheSearchField(in: window, count: 6, backward: true),
                      "Shift-Tab reaches the search field")
    }
}
