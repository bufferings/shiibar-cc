import XCTest
@testable import ShiibarCcCore

/// "Copy as Markdown" serialization (DESIGN.md §4.6 amended, M39 T3): the
/// selected slice of a rendered message writes back to Markdown from the
/// block structure and inline styles — not a byte slice of the original.
final class ConversationsMarkdownSerializerTests: XCTestCase {
    private func rendered(_ role: String, _ text: String) -> RenderedMessage {
        RenderedMessage(role: role, text: text)
    }

    /// Serialize the whole message.
    private func full(_ message: RenderedMessage) -> String {
        ConversationsMarkdownSerializer.markdown(
            rendered: message, start: 0, end: message.renderedText.count
        )
    }

    // MARK: - Inline styles

    func testInlineStylesAreRestored() {
        let message = rendered("assistant", "has **bold**, *italic*, `code`, ~~gone~~, [link](https://example.invalid/a)")
        XCTAssertEqual(
            full(message),
            "has **bold**, *italic*, `code`, ~~gone~~, [link](https://example.invalid/a)"
        )
    }

    func testPartialSliceInsideAStyledRunWrapsJustTheSlice() {
        // Rendered: "keep bold words here", bold on Characters 5..<15.
        let message = rendered("assistant", "keep **bold words** here")
        XCTAssertEqual(
            ConversationsMarkdownSerializer.markdown(rendered: message, start: 7, end: 13),
            "**ld wor**"
        )
    }

    func testLinkTextSerializesAsTheDisplayedLink() {
        // Foundation's parser flattens emphasis inside link text (measured:
        // one run, no intent, link set) — the DISPLAY shows "bold rest" as a
        // plain link, and the copy faithfully serializes what was displayed
        // (§4.6: the Markdown expression of the selection, i.e. of the
        // rendered structure, not the original bytes).
        let message = rendered("assistant", "[**bold** rest](https://example.invalid/x)")
        XCTAssertEqual(full(message), "[bold rest](https://example.invalid/x)")
    }

    // MARK: - Blocks

    func testHeadingRestoresItsMarkerOnlyFromTheBlockHead() {
        let message = rendered("assistant", "## Title here")
        XCTAssertEqual(full(message), "## Title here")
        // A mid-heading slice is just text — no "#" prefix.
        XCTAssertEqual(
            ConversationsMarkdownSerializer.markdown(rendered: message, start: 2, end: 7),
            "tle h"
        )
    }

    func testListItemsRestoreMarkersAndStayOneList() {
        let message = rendered("assistant", "- item one\n- item two")
        XCTAssertEqual(full(message), "- item one\n- item two")
    }

    func testOrderedListKeepsItsLiteralMarker() {
        let message = rendered("assistant", "2) second thing")
        XCTAssertEqual(full(message), "2) second thing")
    }

    func testNestedBulletRestoresIndentation() {
        let message = rendered("assistant", "- top\n  - nested")
        XCTAssertEqual(full(message), "- top\n  - nested")
    }

    func testSliceStartingInsideAListItemContentHasNoMarker() {
        // Rendered "<bullet> item one": content starts at Character 2.
        let message = rendered("assistant", "- item one")
        XCTAssertEqual(
            ConversationsMarkdownSerializer.markdown(rendered: message, start: 4, end: 8),
            "em o"
        )
    }

    func testCodeBlockIsReFencedEvenWhenCutMidBlock() {
        let message = rendered("assistant", "```\nlet a = 1\nlet b = 2\n```")
        XCTAssertEqual(full(message), "```\nlet a = 1\nlet b = 2\n```")
        // Rendered text is "let a = 1\nlet b = 2"; slicing the second line.
        XCTAssertEqual(
            ConversationsMarkdownSerializer.markdown(rendered: message, start: 10, end: 19),
            "```\nlet b = 2\n```"
        )
    }

    func testTableRoundTripsWithSeparatorRow() {
        let message = rendered("assistant", "| a | b |\n|---|---|\n| c | d |")
        XCTAssertEqual(full(message), "| a | b |\n|---|---|\n| c | d |")
    }

    func testPartialTableSelectionEmitsOnlyTouchedCellsWithoutSeparator() {
        // Rendered "a\nb\nc\nd": selecting "c\nd" (offsets 4..<7) touches
        // only the data row — a single pipe row, no separator.
        let message = rendered("assistant", "| a | b |\n|---|---|\n| c | d |")
        XCTAssertEqual(
            ConversationsMarkdownSerializer.markdown(rendered: message, start: 4, end: 7),
            "| c | d |"
        )
    }

    func testPipesInsideCellsAreEscaped() {
        let message = rendered("assistant", "cmd | note\n---|---\n`a \\| b` | uses pipe")
        // The cell's rendered text contains a literal pipe; the write-back
        // escapes it so the copied table stays a table.
        XCTAssertEqual(
            full(message),
            "| cmd | note |\n|---|---|\n| `a \\| b` | uses pipe |"
        )
    }

    // MARK: - Cross-block and user messages

    func testCrossBlockSliceJoinsWithBlankLines() {
        let message = rendered("assistant", "first para\n\n```\ncode\n```")
        // Rendered "first para\ncode": slice from "para" into the code.
        XCTAssertEqual(
            ConversationsMarkdownSerializer.markdown(rendered: message, start: 6, end: 13),
            "para\n\n```\nco\n```"
        )
    }

    func testUserMessageSliceIsVerbatim() {
        // The band shows the user's words unrendered — the slice is the raw
        // slice, markers included.
        let message = rendered("user", "fix **this** now")
        XCTAssertEqual(
            ConversationsMarkdownSerializer.markdown(rendered: message, start: 4, end: 12),
            "**this**"
        )
    }

    func testEmptyAndInvalidRangesSerializeToNothing() {
        let message = rendered("assistant", "text")
        XCTAssertEqual(ConversationsMarkdownSerializer.markdown(rendered: message, start: 2, end: 2), "")
        XCTAssertEqual(ConversationsMarkdownSerializer.markdown(rendered: message, start: 9, end: 12), "")
        XCTAssertEqual(ConversationsMarkdownSerializer.markdown(rendered: message, start: -3, end: 2), "te")
    }

    // MARK: - UTF-16 -> Character conversion (JS selection offsets)

    func testCharacterOffsetConvertsAndSnapsDown() {
        // "<thumbs-up>x": the emoji is 2 UTF-16 units, 1 Character.
        let text = "\u{1F44D}x"
        XCTAssertEqual(ConversationsMarkdownSerializer.characterOffset(utf16Offset: 0, in: text), 0)
        XCTAssertEqual(ConversationsMarkdownSerializer.characterOffset(utf16Offset: 2, in: text), 1)
        XCTAssertEqual(ConversationsMarkdownSerializer.characterOffset(utf16Offset: 3, in: text), 2)
        // Mid-surrogate snaps DOWN (shrinking beats overshooting).
        XCTAssertEqual(ConversationsMarkdownSerializer.characterOffset(utf16Offset: 1, in: text), 0)
        // Out of range clamps.
        XCTAssertEqual(ConversationsMarkdownSerializer.characterOffset(utf16Offset: 99, in: text), 2)
    }

    // MARK: - Supplemented emphasis round-trips

    func testSupplementedEmphasisSerializesBackToMarkers() {
        // CJK-blocked bold is supplemented at render time (§4.6); copying it
        // writes the markers back.
        let message = rendered("assistant", "\u{3042}**\u{300C}x\u{300D}**\u{3044}")
        XCTAssertEqual(full(message), "\u{3042}**\u{300C}x\u{300D}**\u{3044}")
    }
}
