import ShiibarCcCore
import WebKit
import XCTest
@testable import ConversationsWebPaneKit

/// Live-page checks against a real WKWebView (M39 T5): malicious transcript
/// content renders as literal text and never executes (§4.6/§8.38 security
/// discipline), the page builds the DOM the payload describes, highlights
/// are painted ranges (an active selection survives a hit change), and the
/// fold badge shows Core's hidden count.
final class WebPaneSecurityTests: XCTestCase {
    /// Spy for the controller's injectable external-open action: tests must
    /// never launch the user's real browser (out-of-sandbox machine state —
    /// the same principle as the temp-state-dir rule).
    @MainActor
    private final class OpenURLSpy {
        private(set) var urls: [URL] = []
        var onOpen: (() -> Void)?
        func record(_ url: URL) {
            urls.append(url)
            onOpen?()
        }
    }

    @MainActor
    private func loadedController(_ messages: [ConversationMessage]) -> (WebPaneController, OpenURLSpy) {
        let controller = WebPaneController()
        // Every test spies on external opens — no test may reach
        // NSWorkspace, whether or not it expects to navigate.
        let spy = OpenURLSpy()
        controller.openExternalURL = { spy.record($0) }
        // WKWebView needs a real frame for layout-dependent behavior.
        controller.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 800)
        let renderedOnce = expectation(description: "page rendered")
        controller.onRendered = { _ in renderedOnce.fulfill() }
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        controller.load(messages: messages, rendered: rendered, anchorSeq: nil)
        wait(for: [renderedOnce], timeout: 20)
        return (controller, spy)
    }

    /// Evaluate a JS expression and return its result, pumping the run loop.
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
    private func setHits(_ terms: [String], messages: [ConversationMessage], controller: WebPaneController) {
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        let hits = ConversationHits.locations(messageTexts: rendered.map(\.renderedText), terms: terms)
        let applied = expectation(description: "hits applied")
        controller.onHitsApplied = { _ in applied.fulfill() }
        controller.setHits(hits, rendered: rendered, current: hits.isEmpty ? nil : hits.count - 1)
        wait(for: [applied], timeout: 10)
    }

    // MARK: - Malicious input (§4.6: content is untrusted)

    @MainActor
    func testMaliciousTranscriptRendersAsTextAndNeverExecutes() {
        let messages = [
            ConversationMessage(
                seq: 1, role: "user",
                text: "<script>window.pwned = 1</script> & \"quotes\" <img src=x onerror=\"window.pwned=2\">"
            ),
            ConversationMessage(
                seq: 2, role: "assistant",
                text: "```\n<script>window.pwned = 3</script>\n```\n\n[malicious](javascript:window.pwned=4) and [fine](https://example.invalid/x)"
            ),
        ]
        let (controller, openSpy) = loadedController(messages)

        let probe = evaluate(
            """
            JSON.stringify({
              scripts: document.scripts.length,
              images: document.images.length,
              pwned: typeof window.pwned,
              literalScript: document.getElementById('doc').textContent.includes('<script>'),
              literalOnerror: document.getElementById('doc').textContent.includes('onerror'),
              javascriptHrefs: document.querySelectorAll('a[href^="javascript:"]').length,
              httpsLinks: document.querySelectorAll('a[href^="https:"]').length
            })
            """,
            in: controller
        ) as? String ?? ""

        XCTAssertTrue(probe.contains(#""scripts":1"#), "only the page's own script may exist: \(probe)")
        XCTAssertTrue(probe.contains(#""images":0"#), "content markup must not create elements: \(probe)")
        XCTAssertTrue(probe.contains(#""pwned":"undefined""#), "content must never execute: \(probe)")
        XCTAssertTrue(probe.contains(#""literalScript":true"#), "markup must render as literal text: \(probe)")
        XCTAssertTrue(probe.contains(#""literalOnerror":true"#), "markup must render as literal text: \(probe)")
        // Core sanitizes hrefs to http/https; a javascript: link never
        // becomes an anchor at all.
        XCTAssertTrue(probe.contains(#""javascriptHrefs":0"#), probe)
        XCTAssertTrue(probe.contains(#""httpsLinks":1"#), probe)
        // Nothing was clicked: the malicious content must not have reached
        // the external-open path at all.
        XCTAssertEqual(openSpy.urls, [])
    }

    @MainActor
    func testClickingAnHttpsLinkNeverNavigatesThePage() {
        let messages = [
            ConversationMessage(seq: 1, role: "assistant", text: "[go](https://example.invalid/target)"),
        ]
        let (controller, openSpy) = loadedController(messages)
        // Simulated click: the navigation delegate must cancel the
        // navigation AND hand the URL to the injected external-open action
        // (the spy — never the real browser in tests).
        let opened = expectation(description: "external open requested")
        openSpy.onOpen = { opened.fulfill() }
        _ = evaluate("document.querySelector('a').click(); 0", in: controller)
        wait(for: [opened], timeout: 10)
        XCTAssertEqual(openSpy.urls, [URL(string: "https://example.invalid/target")!])
        let location = evaluate("document.location.href", in: controller) as? String
        XCTAssertEqual(location, "about:blank", "the page must never navigate")
        let alive = evaluate("document.querySelectorAll('.msg').length", in: controller) as? Int
        XCTAssertEqual(alive, 1)
    }

    // MARK: - Rendering + highlight behavior (§4.6/§8.38)

    @MainActor
    func testHighlightsArePaintedRangesAndSelectionSurvivesHitChanges() {
        let messages = [
            ConversationMessage(seq: 1, role: "user", text: "find the target here"),
            ConversationMessage(seq: 2, role: "assistant", text: "another target in a **styled target run**"),
        ]
        let (controller, openSpy) = loadedController(messages)

        // The CSS Custom Highlight API must exist on the target OS —
        // in-text highlights depend on it (verified live, not from memory).
        let highlightType = evaluate("typeof Highlight", in: controller) as? String
        XCTAssertEqual(highlightType, "function", "CSS Custom Highlight API unavailable in this WebKit")

        // A cross-message selection set before the hits arrive...
        _ = evaluate(
            """
            (function() {
              const a = document.querySelectorAll('[data-mi]')[0];
              const b = document.querySelectorAll('[data-mi]')[1];
              getSelection().setBaseAndExtent(a, 0, b, b.childNodes.length);
              return getSelection().isCollapsed;
            })()
            """,
            in: controller
        )

        setHits(["target"], messages: messages, controller: controller)

        let probe = evaluate(
            """
            JSON.stringify({
              marks: document.querySelectorAll('mark').length,
              highlightRanges: (CSS.highlights.get('shiibar-hit') || {size: -1}).size,
              currentRanges: (CSS.highlights.get('shiibar-current') || CSS.highlights.get('shiibar-hit-current') || {size: -1}).size,
              selectionAlive: !getSelection().isCollapsed,
              ticks: document.querySelectorAll('#mm .hit').length
            })
            """,
            in: controller
        ) as? String ?? ""

        // No <mark> elements: highlights never mutate the DOM (§8.38), so
        // the selection survives and styled runs never split.
        XCTAssertTrue(probe.contains(#""marks":0"#), probe)
        XCTAssertTrue(probe.contains(#""highlightRanges":2"#), "two non-current hits expected: \(probe)")
        XCTAssertTrue(probe.contains(#""currentRanges":1"#), probe)
        XCTAssertTrue(probe.contains(#""selectionAlive":true"#), "selection must survive setHits: \(probe)")
        XCTAssertTrue(probe.contains(#""ticks":3"#), "one minimap hit line per hit: \(probe)")
        XCTAssertEqual(openSpy.urls, [])
    }

    @MainActor
    func testFoldBadgeShowsCoreHiddenCountAndCopyHelperReturnsRaw() {
        let long = String(repeating: "filler ", count: 90) + "target target" // folds; hits hidden
        let messages = [
            ConversationMessage(seq: 1, role: "assistant", text: long),
        ]
        let (controller, openSpy) = loadedController(messages)
        setHits(["target"], messages: messages, controller: controller)

        let badge = evaluate(
            "(document.querySelector('.expand .cnt') || {textContent: 'none'}).textContent",
            in: controller
        ) as? String
        XCTAssertEqual(badge, "2 matches", "the badge must show Core's hidden-hit count")

        // Chrome is excluded from selection/copy (§4.6): the reply marker
        // and the fold control carry user-select: none.
        let chromeExcluded = evaluate(
            """
            getComputedStyle(document.querySelector('.dot')).webkitUserSelect === 'none' &&
            getComputedStyle(document.querySelector('.expand')).webkitUserSelect === 'none'
            """,
            in: controller
        ) as? Bool
        XCTAssertEqual(chromeExcluded, true)
        XCTAssertEqual(openSpy.urls, [])
    }

    // MARK: - Copy as Markdown (§4.6 amended: selected range serialization)

    /// A uniquely named pasteboard per test — the copy verbs must never
    /// touch the user's general pasteboard from tests (sandbox rule).
    @MainActor
    private func testPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("cc.shiibar.tests." + UUID().uuidString))
    }

    @MainActor
    private func waitForPasteboardString(_ pasteboard: NSPasteboard) -> String? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let string = pasteboard.string(forType: .string) { return string }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    @MainActor
    func testCopyAsMarkdownSerializesTheSelectedRange() {
        let messages = [
            ConversationMessage(seq: 1, role: "assistant", text: "# Title\n\nkeep **bold words** here\n\n- item one\n- item two"),
        ]
        let (controller, openSpy) = loadedController(messages)
        let pasteboard = testPasteboard()
        controller.pasteboard = pasteboard

        // Programmatic selection over the whole message body.
        _ = evaluate(
            """
            (function() {
              const holder = document.querySelector('[data-mi]');
              getSelection().setBaseAndExtent(holder, 0, holder, holder.childNodes.length);
              return !getSelection().isCollapsed;
            })()
            """,
            in: controller
        )

        controller.copyAsMarkdown()
        let copied = waitForPasteboardString(pasteboard)
        XCTAssertEqual(
            copied,
            "# Title\n\nkeep **bold words** here\n\n- item one\n- item two",
            "the selected range must serialize back to Markdown from the block structure"
        )
        XCTAssertEqual(openSpy.urls, [])
    }

}
