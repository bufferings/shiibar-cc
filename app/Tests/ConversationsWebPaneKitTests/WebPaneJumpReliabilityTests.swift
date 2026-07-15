import ShiibarCcCore
import WebKit
import XCTest
@testable import ConversationsWebPaneKit

/// Jump reliability (DESIGN.md §4.6 amended, §8.38(7), M39 T5): every press
/// scrolls to the current hit — even when the index cannot move (a single
/// hit) — and a jump into a folded message auto-expands, scrolls to the
/// now-visible hit, repaints highlights, and refreshes the minimap hit
/// lines. Written as
/// reproducing tests before the fix (owner report: "jumping to a hit in a
/// folded message doesn't navigate; with a single hit it doesn't navigate").
final class WebPaneJumpReliabilityTests: XCTestCase {
    @MainActor
    private func loadedController(_ messages: [ConversationMessage]) -> WebPaneController {
        let controller = WebPaneController()
        controller.openExternalURL = { XCTFail("no test may open a URL: \($0)") }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("cc.shiibar.tests." + UUID().uuidString))
        controller.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        let renderedOnce = expectation(description: "page rendered")
        controller.onRendered = { _ in renderedOnce.fulfill() }
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        controller.load(messages: messages, rendered: rendered, anchorSeq: nil)
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

    @MainActor
    private func setHits(_ terms: [String], messages: [ConversationMessage], controller: WebPaneController, current: Int?) {
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        let hits = ConversationHits.locations(messageTexts: rendered.map(\.renderedText), terms: terms)
        let applied = expectation(description: "hits applied")
        controller.onHitsApplied = { _ in applied.fulfill() }
        controller.setHits(hits, rendered: rendered, current: current)
        wait(for: [applied], timeout: 10)
    }

    /// Filler so the document is much taller than the 400pt viewport.
    private func filler(_ index: Int) -> ConversationMessage {
        ConversationMessage(
            seq: Int64(1000 + index), role: "assistant",
            text: "filler paragraph \(index)\n\nmore filler text to give the document height"
        )
    }

    @MainActor
    private func scrollTop(_ controller: WebPaneController) -> Double {
        (evaluate("document.getElementById('doc').scrollTop", in: controller) as? Double) ?? -1
    }

    // MARK: - (a) a single hit re-scrolls on every press (§4.6: even when
    // the current position cannot change)

    @MainActor
    func testJumpToTheOnlyHitScrollsEveryTime() {
        var messages = (0..<8).map(filler)
        messages.insert(
            ConversationMessage(seq: 1, role: "assistant", text: "the unique needle sits here"),
            at: 4
        )
        let controller = loadedController(messages)
        setHits(["needle"], messages: messages, controller: controller, current: 0)

        controller.jump(to: 0)
        let afterFirstJump = waitForScrollChange(from: -1, in: controller)
        XCTAssertGreaterThan(afterFirstJump, 0, "the first jump must scroll to the hit")

        // Walk away, then press again WITHOUT the index changing: the pane
        // must come back to the hit.
        _ = evaluate("document.getElementById('doc').scrollTop = 0; 0", in: controller)
        XCTAssertEqual(scrollTop(controller), 0)
        controller.jump(to: 0)
        let afterSecondJump = waitForScrollChange(from: 0, in: controller)
        XCTAssertEqual(afterSecondJump, afterFirstJump, accuracy: 2.0,
                       "a repeated press must re-scroll to the same hit")
    }

    /// Poll until the scroll position differs from `from` (the jump's scroll
    /// runs inside an async evaluateJavaScript).
    @MainActor
    private func waitForScrollChange(from: Double, in controller: WebPaneController) -> Double {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let value = scrollTop(controller)
            if value != from, value >= 0 { return value }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return scrollTop(controller)
    }

    // MARK: - (b) a jump into a folded message expands, scrolls, and
    // repaints highlights and minimap hit lines

    @MainActor
    func testJumpIntoAFoldedMessageExpandsScrollsAndRepaints() {
        // The needle sits far past the 500-character fold, in a message
        // surrounded by filler so the scroll actually has to move.
        let folded = String(repeating: "padding words here ", count: 40) + "hidden needle target"
        var messages = (0..<6).map(filler)
        messages.insert(ConversationMessage(seq: 1, role: "assistant", text: folded), at: 3)
        let controller = loadedController(messages)
        setHits(["needle"], messages: messages, controller: controller, current: 0)

        // Reproduce: before the jump the hit is behind the fold — no range.
        let before = evaluate(
            "JSON.stringify({expanded: !!document.querySelector('.expand') && document.querySelector('.expand').textContent.includes('less'), ranges: (CSS.highlights.get('shiibar-hit-current') || {size: -1}).size})",
            in: controller
        ) as? String ?? ""
        XCTAssertTrue(before.contains(#""expanded":false"#), before)

        controller.jump(to: 0)
        let scrolled = waitForScrollChange(from: 0, in: controller)
        XCTAssertGreaterThan(scrolled, 0, "the jump must scroll to the expanded hit")

        let after = evaluate(
            """
            JSON.stringify({
              showLess: Array.from(document.querySelectorAll('.expand')).some(b => b.textContent.includes('Show less')),
              currentRanges: (CSS.highlights.get('shiibar-hit-current') || {size: -1}).size,
              ticks: document.querySelectorAll('#mm .hit').length,
              hitVisible: (function() {
                const doc = document.getElementById('doc');
                const h = CSS.highlights.get('shiibar-hit-current');
                if (!h || h.size !== 1) return false;
                let rect = null;
                h.forEach(r => { rect = r.getBoundingClientRect(); });
                return rect.top >= 0 && rect.bottom <= doc.clientHeight + 4;
              })()
            })
            """,
            in: controller
        ) as? String ?? ""
        XCTAssertTrue(after.contains(#""showLess":true"#), "the fold must auto-expand: \(after)")
        XCTAssertTrue(after.contains(#""currentRanges":1"#), "the highlight must repaint onto the expanded nodes: \(after)")
        XCTAssertTrue(after.contains(#""ticks":1"#), "the minimap hit line must refresh after the expand: \(after)")
        XCTAssertTrue(after.contains(#""hitVisible":true"#), "the hit must end up inside the viewport: \(after)")
    }

    // MARK: - repeated jumps across a fold stay reliable

    @MainActor
    func testRepeatedJumpsBetweenVisibleAndFoldedHitsAlwaysLand() {
        let folded = String(repeating: "padding words here ", count: 40) + "needle in the deep"
        var messages = (0..<6).map(filler)
        messages.insert(ConversationMessage(seq: 1, role: "assistant", text: "needle on the surface"), at: 1)
        messages.insert(ConversationMessage(seq: 2, role: "assistant", text: folded), at: 6)
        let controller = loadedController(messages)
        setHits(["needle"], messages: messages, controller: controller, current: 1)

        controller.jump(to: 1) // into the fold
        _ = waitForScrollChange(from: 0, in: controller)
        let deepTop = scrollTop(controller)
        controller.jump(to: 0) // back to the surface hit
        let surfaceTop = waitForScrollChange(from: deepTop, in: controller)
        XCTAssertNotEqual(surfaceTop, deepTop, "jumping back must move the scroll")
        controller.jump(to: 1) // and into the (already expanded) fold again
        let deepAgain = waitForScrollChange(from: surfaceTop, in: controller)
        XCTAssertEqual(deepAgain, deepTop, accuracy: 4.0, "the expanded hit stays reachable")
    }
}
