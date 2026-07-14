import XCTest
@testable import ShiibarCcCore

/// Markdown block splitting and rendered-text math (DESIGN.md §4.6 rendering
/// grammar): user messages stay verbatim, Claude messages split into fenced
/// code blocks / headings / list items / paragraphs, inline markers are
/// consumed by the standard parser, out-of-scope constructs stay plain, and
/// the fold boundary is counted on the joined rendered text.
final class ConversationsRenderingTests: XCTestCase {
    private func kinds(_ blocks: [MessageBlock]) -> [MessageBlock.Kind] {
        blocks.map(\.kind)
    }

    private func texts(_ blocks: [MessageBlock]) -> [String] {
        blocks.map(\.renderedText)
    }

    // MARK: - User messages (§4.6: the band carries the words unrendered)

    func testUserMessageIsOneVerbatimBlock() {
        let blocks = ConversationsRendering.blocks(role: "user", text: "fix **this** `now`")
        XCTAssertEqual(kinds(blocks), [.userText])
        // No Markdown consumption for the user's own words.
        XCTAssertEqual(texts(blocks), ["fix **this** `now`"])
    }

    func testEmptyUserMessageHasNoBlocks() {
        XCTAssertEqual(ConversationsRendering.blocks(role: "user", text: ""), [])
    }

    // MARK: - Assistant block splitting

    func testParagraphsSplitOnBlankLines() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "first\n\nsecond\nstill second")
        XCTAssertEqual(kinds(blocks), [.paragraph, .paragraph])
        XCTAssertEqual(texts(blocks), ["first", "second\nstill second"])
    }

    func testFencedCodeBlockIsExtracted() {
        let text = "before\n```swift\nlet x = 1\n\nlet y = 2\n```\nafter"
        let blocks = ConversationsRendering.blocks(role: "assistant", text: text)
        XCTAssertEqual(kinds(blocks), [.paragraph, .codeBlock, .paragraph])
        // Fences and the info string are consumed; blank lines inside the
        // fence survive verbatim.
        XCTAssertEqual(texts(blocks)[1], "let x = 1\n\nlet y = 2")
    }

    func testUnclosedFenceRunsToEndOfMessage() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "```\ncode line")
        XCTAssertEqual(kinds(blocks), [.codeBlock])
        XCTAssertEqual(texts(blocks), ["code line"])
    }

    func testTildeFenceAndInnerBackticks() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "~~~\n```\nnested\n```\n~~~")
        XCTAssertEqual(kinds(blocks), [.codeBlock])
        XCTAssertEqual(texts(blocks), ["```\nnested\n```"])
    }

    func testHeadingLevelsAndContent() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "# Top\n\n### Third")
        XCTAssertEqual(kinds(blocks), [.heading(level: 1), .heading(level: 3)])
        XCTAssertEqual(texts(blocks), ["Top", "Third"])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "#hashtag")
        XCTAssertEqual(kinds(blocks), [.paragraph])
        XCTAssertEqual(texts(blocks), ["#hashtag"])
    }

    func testBulletListItems() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "- one\n- two")
        XCTAssertEqual(kinds(blocks), [.listItem(indent: 0), .listItem(indent: 0)])
        // The bullet marker is rendered (visible) text.
        XCTAssertEqual(texts(blocks), ["\u{2022} one", "\u{2022} two"])
    }

    func testNestedBulletIndent() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "- top\n  - nested")
        XCTAssertEqual(kinds(blocks), [.listItem(indent: 0), .listItem(indent: 1)])
    }

    func testOrderedListKeepsLiteralNumbers() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "1. first\n2) second")
        XCTAssertEqual(kinds(blocks), [.listItem(indent: 0), .listItem(indent: 0)])
        XCTAssertEqual(texts(blocks), ["1. first", "2) second"])
    }

    // MARK: - Inline consumption (rendered text = what the reader sees)

    func testInlineMarkersAreConsumedInParagraphs() {
        let blocks = ConversationsRendering.blocks(
            role: "assistant",
            text: "has **bold**, *italic*, `code`, ~~gone~~, [link](https://example.com)"
        )
        XCTAssertEqual(texts(blocks), ["has bold, italic, code, gone, link"])
    }

    func testInlineMarkersAreConsumedInHeadingsAndListItems() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "## A `code` title\n\n- **bold** item")
        XCTAssertEqual(texts(blocks), ["A code title", "\u{2022} bold item"])
    }

    func testUnclosedInlineMarkerStaysLiteral() {
        // The standard parser leaves an unclosed marker verbatim — the
        // fallback is plain text, never a crash (§4.6).
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "unclosed **bold and `tick")
        XCTAssertEqual(texts(blocks), ["unclosed **bold and `tick"])
    }

    func testOutOfScopeConstructsStayPlain() {
        // Blockquotes are outside the §4.6 rendering scope: their marker
        // characters stay visible as plain paragraph text. (Pipe tables
        // moved INTO scope in §8.37 — see the table section below.)
        let quote = ConversationsRendering.blocks(role: "assistant", text: "> quoted")
        XCTAssertEqual(kinds(quote), [.paragraph])
        XCTAssertEqual(texts(quote), ["> quoted"])
    }

    func testCodeBlockContentIsNotInlineParsed() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "```\n**not bold**\n```")
        XCTAssertEqual(texts(blocks), ["**not bold**"])
    }

    // MARK: - Joined rendered text and offsets

    func testJoinedRenderedTextUsesSingleNewlineSeparators() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "# Title\n\npara\n\n- item")
        XCTAssertEqual(ConversationsRendering.joinedRenderedText(blocks), "Title\npara\n\u{2022} item")
        XCTAssertEqual(ConversationsRendering.blockStartOffsets(blocks), [0, 6, 11])
    }

    func testRenderedMessageTiesBlocksTextAndOffsetsTogether() {
        let rendered = RenderedMessage(role: "assistant", text: "**hi**\n\n```\ncode\n```")
        XCTAssertEqual(rendered.renderedText, "hi\ncode")
        XCTAssertEqual(rendered.blockStartOffsets, [0, 3])
        XCTAssertEqual(kinds(rendered.blocks), [.paragraph, .codeBlock])
    }

    func testHitsOnRenderedTextIgnoreConsumedMarkers() {
        // End-to-end with ConversationHits: a term matching only the raw
        // Markdown syntax does not hit the rendered text (§4.6 — the visible
        // characters are the truth).
        let rendered = RenderedMessage(role: "assistant", text: "see **bold** text")
        let hits = ConversationHits.locations(messageTexts: [rendered.renderedText], terms: ["**"])
        XCTAssertTrue(hits.isEmpty)
        let boldHits = ConversationHits.locations(messageTexts: [rendered.renderedText], terms: ["bold"])
        XCTAssertEqual(boldHits, [ConversationHit(messageIndex: 0, start: 4, length: 4)])
    }

    func testTotalRenderedLengthCountsSeparators() {
        XCTAssertEqual(ConversationsRendering.totalRenderedLength(blockLengths: []), 0)
        XCTAssertEqual(ConversationsRendering.totalRenderedLength(blockLengths: [5]), 5)
        XCTAssertEqual(ConversationsRendering.totalRenderedLength(blockLengths: [5, 3]), 9)
    }

    // MARK: - Fold boundary on rendered blocks (§4.6/§9)

    func testFoldReturnsNilWhenWithinLimit() {
        XCTAssertNil(ConversationsRendering.foldedVisibleLengths(blockLengths: [100, 100], limit: 201))
        XCTAssertNil(ConversationsRendering.foldedVisibleLengths(blockLengths: [100, 100], limit: 500))
    }

    func testFoldCutsInsideABlock() {
        // Blocks of 300 and 300 with the separator at offset 300: the cut at
        // 500 shows all of block 0 and 199 characters of block 1
        // (301...499 in joined coordinates).
        let visible = ConversationsRendering.foldedVisibleLengths(blockLengths: [300, 300], limit: 500)
        XCTAssertEqual(visible, [300, 199])
    }

    func testFoldCutOnSeparatorHidesNextBlockEntirely() {
        // Joined length 300 + 1 + 300 = 601; a limit of 300 ends exactly at
        // the separator, so block 1 contributes nothing.
        let visible = ConversationsRendering.foldedVisibleLengths(blockLengths: [300, 300], limit: 300)
        XCTAssertEqual(visible, [300, 0])
    }

    func testFoldNeverBreaksTheBlockSequence() {
        // Later blocks past the cut are present with zero visible characters
        // — the block list shape is preserved for the view.
        let visible = ConversationsRendering.foldedVisibleLengths(blockLengths: [600, 50, 50], limit: 500)
        XCTAssertEqual(visible, [500, 0, 0])
    }

    // MARK: - Pipe tables (§4.6/§8.37)

    /// The rows of the sole table block in `blocks`, as rendered cell text.
    private func tableCellTexts(_ blocks: [MessageBlock]) -> [[String]]? {
        guard blocks.count == 1, case .table(let rows) = blocks[0].kind else { return nil }
        return rows.map { $0.map(\.renderedText) }
    }

    func testTableDetectionRequiresSeparatorRow() {
        // A pipe-containing line WITHOUT a separator row stays a paragraph
        // (§4.6) — the pipes remain visible rendered text.
        let noSeparator = ConversationsRendering.blocks(role: "assistant", text: "a | b\nplain line")
        XCTAssertEqual(kinds(noSeparator), [.paragraph])
        XCTAssertEqual(texts(noSeparator), ["a | b\nplain line"])

        let table = ConversationsRendering.blocks(role: "assistant", text: "a | b\n--|--\n1 | 2")
        XCTAssertEqual(tableCellTexts(table), [["a", "b"], ["1", "2"]])
    }

    func testTableSeparatorColumnCountMustMatchHeader() {
        // The GitHub rule: a lone "---" after a pipe-containing sentence is
        // a 1-column separator against a 2-column header — not a table
        // (otherwise every thematic break after a piped sentence would fake
        // one).
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "not | a table\n---")
        XCTAssertEqual(kinds(blocks), [.paragraph])
        XCTAssertEqual(texts(blocks), ["not | a table\n---"])
    }

    func testTableConsumesOuterPipesSeparatorAndAlignmentColons() {
        let text = "| Col A | Col B |\n|:------|------:|\n| a1    | b1    |"
        let blocks = ConversationsRendering.blocks(role: "assistant", text: text)
        XCTAssertEqual(tableCellTexts(blocks), [["Col A", "Col B"], ["a1", "b1"]])
        // Rendered text is cell characters only, joined with one "\n" per
        // boundary: no pipes, no separator row, no formatting whitespace.
        XCTAssertEqual(blocks[0].renderedText, "Col A\nCol B\na1\nb1")
    }

    func testTableCellStartOffsetsMatchJoinedText() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "ab | c\n---|---\nde | f")
        guard case .table(let rows) = blocks[0].kind else { return XCTFail("expected a table") }
        // Joined: "ab\nc\nde\nf" — offsets 0, 3, 5, 8.
        XCTAssertEqual(rows.flatMap { $0.map(\.startOffset) }, [0, 3, 5, 8])
        XCTAssertEqual(blocks[0].renderedText, "ab\nc\nde\nf")
    }

    func testTableCellsGoThroughInlineParsing() {
        let text = "| Name | Note |\n|---|---|\n| `code` | **bold** rest |"
        let blocks = ConversationsRendering.blocks(role: "assistant", text: text)
        XCTAssertEqual(tableCellTexts(blocks), [["Name", "Note"], ["code", "bold rest"]])
    }

    func testTableSyntaxDoesNotHitSearch() {
        // End-to-end with ConversationHits: pipes and separator hyphens are
        // consumed, so searching them finds nothing; cell text hits at the
        // cell's offset in the joined rendered text.
        let rendered = RenderedMessage(role: "assistant", text: "alpha | beta\n---|---\ngamma | delta")
        XCTAssertTrue(ConversationHits.locations(messageTexts: [rendered.renderedText], terms: ["--"]).isEmpty)
        XCTAssertEqual(
            ConversationHits.locations(messageTexts: [rendered.renderedText], terms: ["delta"]),
            [ConversationHit(messageIndex: 0, start: 17, length: 5)] // "alpha\nbeta\ngamma\n" = 17
        )
    }

    func testTableEndsAtBlankOrNonPipeLine() {
        let text = "a | b\n---|---\n1 | 2\n\nafter"
        let blocks = ConversationsRendering.blocks(role: "assistant", text: text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(tableCellTexts([blocks[0]]), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(blocks[1].kind, .paragraph)
        XCTAssertEqual(blocks[1].renderedText, "after")
    }

    func testBrokenTableRendersWhatItCan() {
        // Inconsistent DATA row column counts keep each row's own cells;
        // empty cells stay as empty rendered text (§4.6: best effort).
        let text = "| h1 | h2 |\n|---|---|\n| only |\n| a |  | extra |"
        let blocks = ConversationsRendering.blocks(role: "assistant", text: text)
        XCTAssertEqual(tableCellTexts(blocks), [["h1", "h2"], ["only"], ["a", "", "extra"]])
    }

    func testEscapedPipeStaysCellContent() {
        let blocks = ConversationsRendering.blocks(
            role: "assistant", text: "cmd | effect\n---|---\n`a \\| b` | pipe inside"
        )
        // "\|" unescapes at table-split time (the GitHub rule), so the pipe
        // stays cell content — even inside a code span, where the inline
        // parser would never unescape it.
        XCTAssertEqual(tableCellTexts(blocks), [["cmd", "effect"], ["a | b", "pipe inside"]])
    }

    func testHeaderOnlyTableIsATable() {
        // Header + separator with zero data rows still renders as a grid.
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "a | b\n---|---")
        XCTAssertEqual(tableCellTexts(blocks), [["a", "b"]])
    }

    func testVisibleTableCellLengthsFoldIntersection() {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: "ab | c\n---|---\nde | f")
        guard case .table(let rows) = blocks[0].kind else { return XCTFail("expected a table") }
        // Joined "ab\nc\nde\nf": a budget of 4 shows "ab", "c", and nothing
        // of "de"/"f" (the cut lands on the separator before "de").
        XCTAssertEqual(
            ConversationsRendering.visibleTableCellLengths(rows: rows, visibleLength: 4),
            [[2, 1], [0, 0]]
        )
        // A budget of 6 cuts mid-"de": that cell shows its 1-character
        // prefix — the same rule as block truncation (§4.6).
        XCTAssertEqual(
            ConversationsRendering.visibleTableCellLengths(rows: rows, visibleLength: 6),
            [[2, 1], [1, 0]]
        )
        // The full length shows everything.
        XCTAssertEqual(
            ConversationsRendering.visibleTableCellLengths(rows: rows, visibleLength: 9),
            [[2, 1], [2, 1]]
        )
    }

    func testTableParticipatesInBlockFoldMath() {
        // The table block's rendered length feeds the existing §9 fold
        // boundary unchanged (its renderedText IS the joined cell text).
        let rendered = RenderedMessage(role: "assistant", text: "intro\n\na | b\n---|---\n1 | 2")
        XCTAssertEqual(rendered.renderedText, "intro\na\nb\n1\n2")
        XCTAssertEqual(rendered.blockStartOffsets, [0, 6])
    }

    // MARK: - Robustness (§4.6: rendering must not fail hard)

    func testDegenerateInputsProduceBlocksWithoutCrashing() {
        XCTAssertEqual(ConversationsRendering.blocks(role: "assistant", text: ""), [])
        XCTAssertEqual(ConversationsRendering.blocks(role: "assistant", text: "\n\n\n"), [])
        // A lone opening fence yields an empty code block, not a crash.
        let loneFence = ConversationsRendering.blocks(role: "assistant", text: "```")
        XCTAssertEqual(kinds(loneFence), [.codeBlock])
        XCTAssertEqual(texts(loneFence), [""])
        // CRLF input: the carriage returns are stripped per line.
        let crlf = ConversationsRendering.blocks(role: "assistant", text: "line one\r\nline two\r\n")
        XCTAssertEqual(texts(crlf), ["line one\nline two"])
    }
}
