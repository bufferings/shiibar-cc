import ShiibarCcCore
import WebKit
import XCTest
@testable import ConversationsWebPaneKit

/// The minimap-as-scrollbar and the bottom cues (§4.6/§8.39, M39 T6): the
/// always-on schematic reflects the block structure at real layout offsets,
/// the thumb tracks the viewport, the end marker and the top scroll shadow
/// follow their visibility rules, and all of it is chrome — unselectable,
/// uncopyable, unsearchable.
final class WebPaneMinimapTests: XCTestCase {
    @MainActor
    private func loadedController(
        _ messages: [ConversationMessage], elapsed: String? = nil
    ) -> WebPaneController {
        let controller = WebPaneController()
        controller.openExternalURL = { XCTFail("no test may open a URL: \($0)") }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("cc.shiibar.tests." + UUID().uuidString))
        controller.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        let renderedOnce = expectation(description: "page rendered")
        controller.onRendered = { _ in renderedOnce.fulfill() }
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        controller.load(messages: messages, rendered: rendered, anchorSeq: nil, elapsed: elapsed)
        wait(for: [renderedOnce], timeout: 20)
        return controller
    }

    @MainActor
    private func evaluate(_ script: String, in controller: WebPaneController) -> Any? {
        var output: Any?
        let done = expectation(description: "js evaluated")
        controller.webView.evaluateJavaScript(script) { result, error in
            XCTAssertNil(error, "evaluateJavaScript failed: \(String(describing: error))")
            output = result
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return output
    }

    private func fixtureMessages() -> [ConversationMessage] {
        var messages: [ConversationMessage] = [
            ConversationMessage(seq: 1, role: "user", text: "please check this"),
            ConversationMessage(seq: 2, role: "assistant", text: "a paragraph\n\n```\ncode block\n```\n\nmore text"),
        ]
        for index in 0..<6 {
            messages.append(ConversationMessage(
                seq: Int64(10 + index), role: "assistant",
                text: "filler paragraph \(index)\n\nwith more text to give the page height"
            ))
        }
        return messages
    }

    // MARK: - Schematic + thumb geometry

    @MainActor
    func testMinimapDrawsTheBlockSchematicAndAViewportThumb() {
        let controller = loadedController(fixtureMessages())
        let probe = evaluate(
            """
            JSON.stringify((function() {
              const mm = document.getElementById('mm');
              const thumb = document.getElementById('mmthumb');
              return {
                bands: mm.querySelectorAll('.band').length,
                texts: mm.querySelectorAll('.txt').length,
                codes: mm.querySelectorAll('.codeb').length,
                hasThumb: !!thumb,
                thumbInside: thumb ? (thumb.offsetTop >= 0 && thumb.offsetTop + thumb.offsetHeight <= mm.clientHeight + 1) : false,
                width: mm.getBoundingClientRect().width
              };
            })())
            """,
            in: controller
        ) as? String ?? ""
        XCTAssertTrue(probe.contains(#""bands":1"#), "one band stripe for the user message: \(probe)")
        XCTAssertTrue(probe.contains(#""codes":1"#), "the code block maps to the intermediate shade: \(probe)")
        XCTAssertTrue(probe.contains(#""hasThumb":true"#), probe)
        XCTAssertTrue(probe.contains(#""thumbInside":true"#), probe)
        XCTAssertTrue(probe.contains(#""width":20"#), "§9: the minimap column is 20pt: \(probe)")
        // Paragraph segments: 2 from the styled message + 12 filler = many.
        XCTAssertFalse(probe.contains(#""texts":0"#), probe)
    }

    @MainActor
    func testThumbTracksTheScrollPosition() {
        let controller = loadedController(fixtureMessages())
        let before = evaluate(
            "document.getElementById('doc').scrollTop = 0; 0; document.getElementById('mmthumb').offsetTop",
            in: controller
        ) as? Int
        // Let the scroll event update the cues.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let atTop = evaluate("document.getElementById('mmthumb').offsetTop", in: controller) as? Int
        XCTAssertEqual(atTop, 0, "at scrollTop 0 the thumb sits at the top (before=\(String(describing: before)))")

        _ = evaluate("document.getElementById('doc').scrollTop = 99999; 0", in: controller)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let atBottom = evaluate(
            "JSON.stringify({top: document.getElementById('mmthumb').offsetTop, ok: document.getElementById('mmthumb').offsetTop > 0})",
            in: controller
        ) as? String ?? ""
        XCTAssertTrue(atBottom.contains(#""ok":true"#), "the thumb must move down with the scroll: \(atBottom)")
    }

    @MainActor
    func testMinimapShowsHitLinesWithACurrentOne() {
        let messages = fixtureMessages()
        let controller = loadedController(messages)
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        let hits = ConversationHits.locations(messageTexts: rendered.map(\.renderedText), terms: ["filler"])
        let applied = expectation(description: "hits applied")
        controller.onHitsApplied = { _ in applied.fulfill() }
        controller.setHits(hits, rendered: rendered, current: 0)
        wait(for: [applied], timeout: 10)

        let probe = evaluate(
            "JSON.stringify({lines: document.querySelectorAll('#mm .hit').length, current: document.querySelectorAll('#mm .hit.cur').length, oldTicks: document.querySelectorAll('.tick').length})",
            in: controller
        ) as? String ?? ""
        XCTAssertTrue(probe.contains(#""lines":6"#), "one line per hit: \(probe)")
        XCTAssertTrue(probe.contains(#""current":1"#), probe)
        XCTAssertTrue(probe.contains(#""oldTicks":0"#), "the tick overlay is gone: \(probe)")
    }

    // MARK: - Bottom cues

    @MainActor
    func testEndMarkerShowsElapsedAndStaysOutOfCopies() {
        let controller = loadedController(fixtureMessages(), elapsed: "3h")
        let text = evaluate("document.querySelector('.endcap').textContent", in: controller) as? String
        XCTAssertEqual(text, "Latest message \u{00B7} 3h ago")
        let unselectable = evaluate(
            "getComputedStyle(document.querySelector('.endcap')).webkitUserSelect === 'none'",
            in: controller
        ) as? Bool
        XCTAssertEqual(unselectable, true)
        // A whole-document selection produces ranges over content only —
        // the end marker has no node-map entry.
        let markdown = evaluate(
            """
            (function() {
              getSelection().selectAllChildren(document.getElementById('doc'));
              return JSON.stringify(shiibarAPI.selectionRanges());
            })()
            """,
            in: controller
        ) as? String ?? ""
        XCTAssertFalse(markdown.isEmpty)
        // Ranges never extend past the last message's rendered length.
        XCTAssertFalse(markdown.contains("Latest"), markdown)
    }

    @MainActor
    func testEndMarkerWithoutElapsedOmitsTheSuffix() {
        let controller = loadedController(fixtureMessages(), elapsed: nil)
        let text = evaluate("document.querySelector('.endcap').textContent", in: controller) as? String
        XCTAssertEqual(text, "Latest message")
    }

    @MainActor
    func testTopShadowShowsOnlyWhileContentExtendsAbove() {
        let controller = loadedController(fixtureMessages())
        // Loaded at the bottom (§4.6): content extends above -> shadow on.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let atBottom = evaluate(
            "parseFloat(document.getElementById('topshadow').style.opacity)",
            in: controller
        ) as? Double
        XCTAssertEqual(atBottom ?? 0, 1, "scrolled down, the shadow shows")

        _ = evaluate("document.getElementById('doc').scrollTop = 0; 0", in: controller)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let atTop = evaluate(
            "parseFloat(document.getElementById('topshadow').style.opacity)",
            in: controller
        ) as? Double
        XCTAssertEqual(atTop ?? -1, 0, "at the very top the shadow fades out")
    }
}
