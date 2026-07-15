import XCTest
@testable import ShiibarCcCore

/// The conservative emphasis supplement (DESIGN.md §4.6/§8.38, M39 T4):
/// markers the standard parser leaves literal next to CJK punctuation
/// become emphasis when — and only when — the pairing is unambiguous.
/// CJK content is written as unicode escapes to keep the source ASCII
/// (repo language rule); the visible strings are Japanese.
final class ConversationsEmphasisSupplementTests: XCTestCase {
    /// Blocks for one assistant message (the supplement runs inside the
    /// inline build, so going through the public block API tests the real
    /// pipeline).
    private func block(_ markdown: String) -> MessageBlock {
        let blocks = ConversationsRendering.blocks(role: "assistant", text: markdown)
        XCTAssertEqual(blocks.count, 1)
        return blocks[0]
    }

    /// (text, isBold, isItalic, isStruck) per run of a block.
    private func styledRuns(_ block: MessageBlock) -> [(String, Bool, Bool, Bool)] {
        var out: [(String, Bool, Bool, Bool)] = []
        for run in block.text.runs {
            let intent = run.inlinePresentationIntent ?? []
            out.append((
                String(block.text.characters[run.range]),
                intent.contains(.stronglyEmphasized),
                intent.contains(.emphasized),
                intent.contains(.strikethrough)
            ))
        }
        return out
    }

    // MARK: - Supplemented cases (parser-verified flanking failures)

    func testBoldNextToCJKBracketsIsSupplemented() {
        // "a**[x]**i" with CJK brackets: the standard parser leaves it all
        // literal (flanking); the supplement renders the bold and consumes
        // the markers — rendered text loses the asterisks.
        let result = block("\u{3042}**\u{300C}x\u{300D}**\u{3044}")
        XCTAssertEqual(result.renderedText, "\u{3042}\u{300C}x\u{300D}\u{3044}")
        XCTAssertEqual(styledRuns(result).map(\.0), ["\u{3042}", "\u{300C}x\u{300D}", "\u{3044}"])
        XCTAssertEqual(styledRuns(result).map(\.1), [false, true, false])
    }

    func testOwnersExactExampleInSentenceContext() {
        // The smoke finding: "M36 deha **(table-and-quote quote)** toshita"
        // rendered with literal asterisks. Post-supplement it is bold.
        let sentence = "M36 \u{3067}\u{306F}**\u{8868}\u{3068}\u{5F15}\u{7528}\u{306F}"
            + "\u{300C}\u{7D20}\u{306E}\u{30C6}\u{30AD}\u{30B9}\u{30C8}\u{306E}\u{307E}\u{307E}\u{300D}**"
            + "\u{3068}\u{3057}\u{305F}"
        let result = block(sentence)
        XCTAssertFalse(result.renderedText.contains("*"), "markers must be consumed")
        let bolded = styledRuns(result).filter(\.1).map(\.0)
        XCTAssertEqual(bolded, [
            "\u{8868}\u{3068}\u{5F15}\u{7528}\u{306F}"
                + "\u{300C}\u{7D20}\u{306E}\u{30C6}\u{30AD}\u{30B9}\u{30C8}\u{306E}\u{307E}\u{307E}\u{300D}"
        ])
    }

    func testStrikethroughAndItalicVariantsAreSupplemented() {
        // "a~~[x]~~i" and "a*[x]*i" fail flanking the same way.
        let struck = block("\u{3042}~~\u{300C}x\u{300D}~~\u{3044}")
        XCTAssertEqual(struck.renderedText, "\u{3042}\u{300C}x\u{300D}\u{3044}")
        XCTAssertEqual(styledRuns(struck).map(\.3), [false, true, false])

        let italic = block("\u{3042}*\u{300C}x\u{300D}*\u{3044}")
        XCTAssertEqual(italic.renderedText, "\u{3042}\u{300C}x\u{300D}\u{3044}")
        XCTAssertEqual(styledRuns(italic).map(\.2), [false, true, false])
    }

    func testBoldBeforeCJKPeriodViaIdeographicComma() {
        // "a**[x]**(period)" — the closing marker touches the ideographic
        // full stop.
        let result = block("\u{3042}**\u{300C}x\u{300D}**\u{3002}")
        XCTAssertEqual(result.renderedText, "\u{3042}\u{300C}x\u{300D}\u{3002}")
        XCTAssertTrue(styledRuns(result).contains { $0.0 == "\u{300C}x\u{300D}" && $0.1 })
    }

    func testSupplementAppliesInsideTableCells() {
        let blocks = ConversationsRendering.blocks(
            role: "assistant",
            text: "h1 | h2\n---|---\n\u{3042}**\u{300C}x\u{300D}**\u{3044} | plain"
        )
        guard case .table(let rows) = blocks[0].kind else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[1][0].renderedText, "\u{3042}\u{300C}x\u{300D}\u{3044}")
    }

    // MARK: - Conservative non-cases (must stay literal)

    func testAlreadyParsedEmphasisIsUntouched() {
        // ASCII flanking works; the supplement must not double-process.
        let result = block("a **bold** b")
        XCTAssertEqual(result.renderedText, "a bold b")
        XCTAssertEqual(styledRuns(result).filter(\.1).map(\.0), ["bold"])
    }

    func testLoneMarkerStaysLiteral() {
        let result = block("lone ** here")
        XCTAssertEqual(result.renderedText, "lone ** here")
    }

    func testOddMarkerCountStaysLiteral() {
        // Three markers: unbalanced — nothing is supplemented.
        let result = block("\u{3042}**\u{300C}a\u{300D}**\u{3044}**\u{3048}")
        XCTAssertTrue(result.renderedText.contains("**"))
    }

    func testNestedEmphasisStaysLiteral() {
        // "a**[*x*]**i": the parser consumes the inner italic; the leftover
        // outer pair wraps existing emphasis — nested, so it stays literal
        // (a miss over a false positive, §4.6).
        let result = block("\u{3042}**\u{300C}*x*\u{300D}**\u{3044}")
        XCTAssertTrue(result.renderedText.contains("**"))
        XCTAssertEqual(styledRuns(result).filter(\.2).map(\.0), ["x"], "the parser's italic survives")
    }

    func testMisPairedMultiPairFragmentStaysAsParsed() {
        // Two CJK-blocked pairs in one fragment: the parser mis-pairs the
        // middle markers (measured); the leftovers wrap existing emphasis,
        // so the supplement conservatively declines.
        let result = block("\u{3042}**\u{300C}a\u{300D}**\u{3044}\u{3068}\u{3046}**\u{300C}b\u{300D}**\u{3048}")
        XCTAssertTrue(result.renderedText.contains("**"), "ambiguous fragment must stay as parsed")
    }

    func testMarkersInsideCodeSpansStayLiteral() {
        // Backticked markers are literal by design; the supplement must not
        // reach into code spans.
        let result = block("see `**x**` here")
        XCTAssertEqual(result.renderedText, "see **x** here")
        XCTAssertTrue(styledRuns(result).contains { $0.0 == "**x**" })
    }

    func testTripleMarkerRunsAreNeverCandidates() {
        let result = block("\u{3042}***\u{300C}x\u{300D}***\u{3044}")
        // Runs of 3+ are ambiguous (bold? italic? both?) — stay literal
        // unless the parser itself resolved them.
        if result.renderedText.contains("*") {
            XCTAssertTrue(result.renderedText.contains("***"))
        }
    }

    // MARK: - Rendered-text consistency (§4.6: hits/fold see the display)

    func testHitsAndFoldSeePostSupplementCoordinates() {
        // The supplement runs before rendered text is derived, so a search
        // for the content finds it at the DISPLAYED offset, and the markers
        // are not searchable — exactly like parser-consumed markers.
        let rendered = RenderedMessage(role: "assistant", text: "\u{3042}**\u{300C}x\u{300D}**\u{3044}")
        XCTAssertEqual(rendered.renderedText, "\u{3042}\u{300C}x\u{300D}\u{3044}")
        let hits = ConversationHits.locations(messageTexts: [rendered.renderedText], terms: ["\u{300C}x"])
        XCTAssertEqual(hits, [ConversationHit(messageIndex: 0, start: 1, length: 2)])
        XCTAssertTrue(ConversationHits.locations(messageTexts: [rendered.renderedText], terms: ["**"]).isEmpty)
    }
}
