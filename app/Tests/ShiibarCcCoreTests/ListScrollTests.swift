import XCTest
@testable import ShiibarCcCore

/// The list's scroll decisions (DESIGN.md §4.5 "row selection": the minimum
/// scroll that shows the whole selected row; "the popover and the window
/// share one state": the list scroll position).
final class ListScrollTests: XCTestCase {
    private let viewport = ListViewport(top: 200, height: 500, contentHeight: 2_000)

    private func row(_ top: Double, _ bottom: Double, _ id: String = "x") -> ListRowExtent {
        ListRowExtent(key: .conversation(sessionID: id), top: top, bottom: bottom)
    }

    // MARK: - Reveal

    func testRevealTable() {
        let cases: [(name: String, row: ListRowExtent, expected: Double?)] = [
            ("fully visible: no scroll", row(300, 369), nil),
            ("touching both edges exactly: no scroll", row(200, 700), nil),
            ("below: bottom edge aligns", row(680, 749), 249),
            ("far below: bottom edge aligns", row(1_500, 1_569), 1_069),
            ("above: top edge aligns", row(150, 219), 150),
            ("far above: top edge aligns", row(0, 69), 0),
            ("taller than the viewport: top aligns", row(400, 1_000), 400),
        ]
        for c in cases {
            XCTAssertEqual(ListReveal.revealTop(viewport: viewport, row: c.row), c.expected, c.name)
        }
    }

    func testRevealClampsToTheContent() {
        let short = ListViewport(top: 100, height: 500, contentHeight: 650)
        XCTAssertEqual(ListReveal.revealTop(viewport: short, row: row(590, 659)), 150, "never past the end")
        let top = ListViewport(top: 10, height: 500, contentHeight: 2_000)
        XCTAssertEqual(ListReveal.revealTop(viewport: top, row: row(-5, 60)), 0, "never above the start")
        let atEnd = ListViewport(top: 150, height: 500, contentHeight: 650)
        XCTAssertNil(ListReveal.revealTop(viewport: atEnd, row: row(600, 680)), "no move when clamped to the current top")
    }

    /// The first row of the whole list scrolls the list to its very top, so
    /// the section header above it shows, even when the row is visible.
    func testRevealFirstRowScrollsToTheVeryTop() {
        let first = row(31, 100)
        let hidden = ListViewport(top: 400, height: 500, contentHeight: 2_000)
        XCTAssertEqual(ListReveal.revealTop(viewport: hidden, row: first, isFirstRow: true), 0, "hidden above: top")
        let underHeading = ListViewport(top: 31, height: 500, contentHeight: 2_000)
        XCTAssertEqual(
            ListReveal.revealTop(viewport: underHeading, row: first, isFirstRow: true), 0,
            "fully visible but scrolled by the heading: top"
        )
        let atTop = ListViewport(top: 0, height: 500, contentHeight: 2_000)
        XCTAssertNil(ListReveal.revealTop(viewport: atTop, row: first, isFirstRow: true), "already at the top: no scroll")
        let short = ListViewport(top: 0, height: 500, contentHeight: 300)
        XCTAssertNil(ListReveal.revealTop(viewport: short, row: first, isFirstRow: true), "content shorter than the viewport")
    }

    /// The very top respects the top inset: the unobscured top is 0, i.e. the
    /// clip view sits at minus the inset.
    func testRevealFirstRowUnderAnInset() {
        let first = row(31, 100)
        let scrolled = ListViewport(clipTop: 0, clipHeight: 594, topInset: 46, bottomInset: 0, contentHeight: 1_726)
        let top = ListReveal.revealTop(viewport: scrolled, row: first, isFirstRow: true)
        XCTAssertEqual(top, 0)
        XCTAssertEqual(top.map { ListViewport.clipTop(forTop: $0, topInset: 46) }, -46)
        let atTop = ListViewport(clipTop: -46, clipHeight: 594, topInset: 46, bottomInset: 0, contentHeight: 1_726)
        XCTAssertNil(ListReveal.revealTop(viewport: atTop, row: first, isFirstRow: true))
    }

    /// Any other row keeps the minimum scroll.
    func testRevealNonFirstRowKeepsTheMinimumScroll() {
        let underHeading = ListViewport(top: 31, height: 500, contentHeight: 2_000)
        XCTAssertNil(ListReveal.revealTop(viewport: underHeading, row: row(131, 200), isFirstRow: false), "visible: no scroll")
        XCTAssertEqual(ListReveal.revealTop(viewport: viewport, row: row(150, 219), isFirstRow: false), 150, "above: top edge aligns")
        XCTAssertEqual(ListReveal.revealTop(viewport: viewport, row: row(680, 749), isFirstRow: false), 249, "below: bottom edge aligns")
    }

    // MARK: - Shared scroll position

    private let rows = [
        ListRowExtent(key: .running(target: "t0"), top: 31, bottom: 100),
        ListRowExtent(key: .conversation(sessionID: "a"), top: 131, bottom: 200),
        ListRowExtent(key: .conversation(sessionID: "b"), top: 200, bottom: 269),
    ]

    func testCaptureTakesTheRowAtTheTopEdge() {
        func capture(_ top: Double) -> ListScrollAnchor? {
            ListScrollAnchor.capture(viewport: ListViewport(top: top, height: 300, contentHeight: 600), rows: rows)
        }
        XCTAssertEqual(capture(0), ListScrollAnchor(key: .running(target: "t0"), offset: -31), "header above the first row")
        XCTAssertEqual(capture(150), ListScrollAnchor(key: .conversation(sessionID: "a"), offset: 19))
        XCTAssertEqual(capture(200), ListScrollAnchor(key: .conversation(sessionID: "b"), offset: 0))
        XCTAssertEqual(capture(290), ListScrollAnchor(key: .conversation(sessionID: "b"), offset: 90), "past the last row")
        XCTAssertNil(ListScrollAnchor.capture(viewport: viewport, rows: []))
    }

    func testRestoreFollowsTheRow() {
        let anchor = ListScrollAnchor(key: .conversation(sessionID: "a"), offset: 19)
        let viewport = ListViewport(top: 0, height: 300, contentHeight: 1_000)
        XCTAssertEqual(anchor.restoredTop(viewport: viewport, rows: rows), 150)
        let moved = rows.map { ListRowExtent(key: $0.key, top: $0.top + 69, bottom: $0.bottom + 69) }
        XCTAssertEqual(anchor.restoredTop(viewport: viewport, rows: moved), 219, "a row inserted above keeps the same row in view")
        XCTAssertNil(anchor.restoredTop(viewport: viewport, rows: [rows[0]]), "the row is gone: stay")
        let first = ListScrollAnchor(key: .running(target: "t0"), offset: -31)
        XCTAssertEqual(first.restoredTop(viewport: viewport, rows: rows), 0)
        let short = ListViewport(top: 0, height: 300, contentHeight: 400)
        XCTAssertEqual(anchor.restoredTop(viewport: short, rows: rows), 100, "clamped to the end")
    }

    // MARK: - Content insets

    /// A clip view with a 46pt top inset at its topmost position (bounds
    /// origin -46): the unobscured top is 0 and the inset is not visible.
    func testInsetViewportExcludesTheInsets() {
        let inset = ListViewport(clipTop: -46, clipHeight: 594, topInset: 46, bottomInset: 10, contentHeight: 1_726)
        XCTAssertEqual(inset, ListViewport(top: 0, height: 538, contentHeight: 1_726))
        XCTAssertEqual(inset.maxTop, 1_188)
        XCTAssertEqual(ListViewport.clipTop(forTop: 0, topInset: 46), -46, "the top of the list sits below the inset")
        XCTAssertEqual(ListViewport.clipTop(forTop: 1_188, topInset: 46), 1_142)
        let plain = ListViewport(clipTop: 120, clipHeight: 548, topInset: 0, bottomInset: 0, contentHeight: 1_726)
        XCTAssertEqual(plain, ListViewport(top: 120, height: 548, contentHeight: 1_726))
    }

    /// A row under the top inset is not visible: revealing it scrolls.
    func testRevealTreatsARowUnderTheInsetAsHidden() {
        let viewport = ListViewport(clipTop: 0, clipHeight: 594, topInset: 46, bottomInset: 0, contentHeight: 1_726)
        let top = ListReveal.revealTop(viewport: viewport, row: row(31, 100))
        XCTAssertEqual(top, 31)
        XCTAssertEqual(top.map { ListViewport.clipTop(forTop: $0, topInset: 46) }, -15)
    }

    /// The same top row on two surfaces whose insets differ (a popover
    /// without one, a window with one).
    func testAnchorRestoresTheSameRowAcrossInsets() {
        let popover = ListViewport(clipTop: 150, clipHeight: 552, topInset: 0, bottomInset: 0, contentHeight: 1_000)
        let anchor = ListScrollAnchor.capture(viewport: popover, rows: rows)
        XCTAssertEqual(anchor, ListScrollAnchor(key: .conversation(sessionID: "a"), offset: 19))
        let window = ListViewport(clipTop: -46, clipHeight: 594, topInset: 46, bottomInset: 0, contentHeight: 1_000)
        let top = anchor?.restoredTop(viewport: window, rows: rows)
        XCTAssertEqual(top, 150, "the same unobscured top")
        XCTAssertEqual(top.map { ListViewport.clipTop(forTop: $0, topInset: 46) }, 104)
    }
}
