import XCTest
@testable import ShiibarCcCore

/// The Core -> page payload (DESIGN.md §4.6 rendering engine, §8.38, M39
/// T5): block/cell structure, the grapheme -> UTF-16 offset conversion at
/// the boundary (JS strings are UTF-16; Core counts Characters), fold-cut
/// conversion, hit conversion with the hidden flag, and href sanitization.
final class ConversationsWebPayloadTests: XCTestCase {
    private func message(_ seq: Int64, _ role: String, _ text: String) -> ConversationMessage {
        ConversationMessage(seq: seq, role: role, text: text)
    }

    private func build(_ messages: [ConversationMessage]) -> WebPanePayload {
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        return ConversationsWebPayload.payload(messages: messages, rendered: rendered)
    }

    // MARK: - UTF-16 conversion (the emoji rule, §8.38)

    func testEmojiShiftsUTF16OffsetsButNotStructure() {
        // "Hi <thumbs-up> **bold**": the emoji is 1 Character but 2 UTF-16
        // units, so everything after it shifts by one unit.
        let payload = build([message(1, "assistant", "Hi \u{1F44D} **bold**")])
        let block = payload.messages[0].blocks[0]
        XCTAssertEqual(block.kind, "p")
        XCTAssertEqual(block.text, "Hi \u{1F44D} bold")
        // Rendered: 9 Characters, 10 UTF-16 units.
        XCTAssertEqual(payload.messages[0].len, 10)
        // The bold run starts at Character 5 == UTF-16 offset 6.
        XCTAssertEqual(block.runs, [WebPaneRun(
            s: 6, l: 4, code: nil, bold: true, italic: nil, strike: nil, href: nil
        )])
    }

    func testHitsConvertToUTF16WithHiddenFlag() {
        let messages = [message(1, "assistant", "Hi \u{1F44D} **bold**")]
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        let hits = ConversationHits.locations(
            messageTexts: rendered.map(\.renderedText), terms: ["bold"]
        )
        // Core hit at Character 5; payload hit at UTF-16 unit 6.
        XCTAssertEqual(hits, [ConversationHit(messageIndex: 0, start: 5, length: 4)])
        XCTAssertEqual(
            ConversationsWebPayload.hits(hits, rendered: rendered),
            [WebPaneHit(m: 0, s: 6, l: 4, hidden: false)]
        )
    }

    func testHiddenFlagMatchesCoreRequiresExpansion() {
        // A hit past the 500-Character fold carries hidden=true (§4.6: the
        // page's badge and auto-expand act on Core's flag, no recompute).
        let text = String(repeating: "a", count: 600) + " target"
        let messages = [message(1, "assistant", text)]
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        let hits = ConversationHits.locations(
            messageTexts: rendered.map(\.renderedText), terms: ["target"]
        )
        let paneHits = ConversationsWebPayload.hits(hits, rendered: rendered)
        XCTAssertEqual(paneHits.count, 1)
        XCTAssertTrue(paneHits[0].hidden)
    }

    // MARK: - Fold cut conversion

    func testFoldedLenConvertsTheCharacterCutToUTF16() {
        // An emoji inside the fold prefix: 500 visible Characters become 501
        // UTF-16 units.
        let text = "\u{1F44D}" + String(repeating: "a", count: 599)
        let payload = build([message(1, "assistant", text)])
        let paneMessage = payload.messages[0]
        XCTAssertTrue(paneMessage.folds)
        XCTAssertEqual(paneMessage.blocks[0].foldedLen, 501)
        // Unfolded total: 600 Characters = 601 UTF-16 units.
        XCTAssertEqual(paneMessage.len, 601)
    }

    func testUnfoldedMessageFoldedLenEqualsFullLength() {
        let payload = build([message(1, "assistant", "short")])
        XCTAssertFalse(payload.messages[0].folds)
        XCTAssertEqual(payload.messages[0].blocks[0].foldedLen, 5)
    }

    // MARK: - Table cells

    func testTableCellOffsetsAreCumulativeUTF16() throws {
        // Joined rendered text: "a\nb\n<thumbs-up>x\nc" — cell starts at
        // UTF-16 units 0, 2, 4, 8 (the emoji cell is 3 units + separator).
        let payload = build([message(1, "assistant", "a | b\n---|---\n\u{1F44D}x | c")])
        let block = payload.messages[0].blocks[0]
        XCTAssertEqual(block.kind, "table")
        let rows = try XCTUnwrap(block.rows)
        XCTAssertEqual(rows.map { $0.map(\.text) }, [["a", "b"], ["\u{1F44D}x", "c"]])
        XCTAssertEqual(rows.map { $0.map(\.start) }, [[0, 2], [4, 8]])
        XCTAssertEqual(payload.messages[0].len, 9)
    }

    // MARK: - Href sanitization (§4.6: only http/https reach the page)

    func testJavascriptHrefIsDropped() {
        let payload = build([message(1, "assistant", "[x](javascript:alert(1)) and [ok](https://example.invalid)")])
        let runs = payload.messages[0].blocks[0].runs ?? []
        XCTAssertEqual(runs.compactMap(\.href), ["https://example.invalid"])
    }

    // MARK: - Structure and user messages

    func testUserMessageIsOneVerbatimUserBlock() {
        let payload = build([message(7, "user", "fix **this**")])
        let paneMessage = payload.messages[0]
        XCTAssertEqual(paneMessage.role, "user")
        XCTAssertEqual(paneMessage.blocks.map(\.kind), ["user"])
        // No Markdown consumption for the user's own words (§4.6).
        XCTAssertEqual(paneMessage.blocks[0].text, "fix **this**")
    }

    func testBlockKindsAndStartsMirrorCore() {
        let payload = build([message(1, "assistant", "# T\n\npara\n\n- item\n\n```\ncode\n```")])
        let blocks = payload.messages[0].blocks
        XCTAssertEqual(blocks.map(\.kind), ["h", "p", "li", "code"])
        // Rendered: "T\npara\n<bullet> item\ncode" — all-ASCII except the
        // bullet (1 unit), so starts match Core's Character offsets.
        XCTAssertEqual(blocks.map(\.start), [0, 2, 7, 14])
        XCTAssertEqual(blocks[3].text, "code")
    }

    // MARK: - End-marker elapsed (§4.6/§8.39: payload-carried)

    func testElapsedRidesThePayloadForTheEndMarker() {
        let messages = [message(1, "user", "hi")]
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        let payload = ConversationsWebPayload.payload(messages: messages, rendered: rendered, elapsed: "3h")
        XCTAssertEqual(payload.elapsed, "3h")
        XCTAssertTrue(ConversationsWebPayload.encodeJSON(payload).contains(#""elapsed":"3h""#))
        // Absent elapsed encodes to nothing (the golden test stays stable).
        XCTAssertNil(ConversationsWebPayload.payload(messages: messages, rendered: rendered).elapsed)
    }

    // MARK: - Golden JSON (stable bridge encoding)

    func testGoldenJSONForATinyPayload() {
        let payload = build([message(1, "user", "hi")])
        XCTAssertEqual(
            ConversationsWebPayload.encodeJSON(payload),
            #"{"messages":[{"blocks":[{"foldedLen":2,"kind":"user","start":0,"text":"hi"}],"folds":false,"len":2,"role":"user","seq":1}]}"#
        )
    }
}
