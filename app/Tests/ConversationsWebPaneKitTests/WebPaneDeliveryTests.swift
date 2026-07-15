import ShiibarCcCore
import WebKit
import XCTest
@testable import ConversationsWebPaneKit

/// Payload delivery reliability (§8.38(7), M39 T5 "blank pane until an
/// interaction"): loads are generation-tagged and acked by the page; rapid
/// consecutive loads must end with the LATEST conversation rendered; a
/// WebContent process termination must recover by reloading the page and
/// replaying the latest state.
final class WebPaneDeliveryTests: XCTestCase {
    @MainActor
    private func makeController() -> WebPaneController {
        let controller = WebPaneController()
        controller.openExternalURL = { XCTFail("no test may open a URL: \($0)") }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("cc.shiibar.tests." + UUID().uuidString))
        controller.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
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

    private func conversation(_ marker: String, count: Int) -> [ConversationMessage] {
        (0..<count).map {
            ConversationMessage(seq: Int64($0), role: "assistant", text: "\(marker) message \($0)")
        }
    }

    @MainActor
    private func load(_ messages: [ConversationMessage], into controller: WebPaneController) {
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        controller.load(messages: messages, rendered: rendered, anchorSeq: nil)
    }

    // MARK: - Loads sent before the page is ready still render (the queue)

    @MainActor
    func testLoadInjectedBeforeReadyRenders() {
        let controller = makeController()
        let rendered = expectation(description: "rendered")
        controller.onRendered = { _ in rendered.fulfill() }
        // Immediately after init the page has not posted ready yet — this is
        // the cold-start path every selection takes.
        load(conversation("early", count: 3), into: controller)
        wait(for: [rendered], timeout: 20)
        let count = evaluate("document.querySelectorAll('[data-mi]').length", in: controller) as? Int
        XCTAssertEqual(count, 3)
        // (§8.38(8)) The sized path dispatches immediately — no gating — and
        // renders into a real viewport.
        XCTAssertGreaterThan(controller.lastRenderedAck?.viewportHeight ?? -1, 0)
    }

    // MARK: - Rapid consecutive loads: the LATEST generation wins

    @MainActor
    func testRapidConsecutiveLoadsRenderTheLatestConversation() {
        let controller = makeController()
        var renderCount = 0
        let renderedTwice = expectation(description: "both loads rendered")
        renderedTwice.expectedFulfillmentCount = 2
        controller.onRendered = { _ in
            renderCount += 1
            renderedTwice.fulfill()
        }
        // Two selections in quick succession, both queued before ready —
        // the second must be what ends up on screen.
        load(conversation("first", count: 2), into: controller)
        load(conversation("second", count: 5), into: controller)
        wait(for: [renderedTwice], timeout: 20)

        let probe = evaluate(
            "JSON.stringify({count: document.querySelectorAll('[data-mi]').length, hasSecond: document.getElementById('doc').textContent.includes('second message 4'), hasFirst: document.getElementById('doc').textContent.includes('first message')})",
            in: controller
        ) as? String ?? ""
        XCTAssertTrue(probe.contains(#""count":5"#), probe)
        XCTAssertTrue(probe.contains(#""hasSecond":true"#), probe)
        XCTAssertTrue(probe.contains(#""hasFirst":false"#), "the older generation must not survive: \(probe)")
        XCTAssertEqual(renderCount, 2, "every generation renders; the last one wins")
    }

    // MARK: - The blank-pane fix (§8.38(8), field-confirmed): loads into a
    // zero-bounds view are HELD and flushed on the first nonzero layout

    @MainActor
    func testHeldLoadFlushesOnFirstNonzeroLayoutWithARealViewport() {
        let controller = WebPaneController() // frame stays .zero — the field sequence
        controller.openExternalURL = { XCTFail("no test may open a URL: \($0)") }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("cc.shiibar.tests." + UUID().uuidString))
        var renders = 0
        controller.onRendered = { _ in renders += 1 }
        load(conversation("held", count: 3), into: controller)
        controller.setTextSize(15)

        // Held, not dispatched into the void: no ack while unsized.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(controller.lastRenderedAck, "a zero-bounds load must be held, not rendered at 0x0")
        XCTAssertEqual(renders, 0)

        // The view gets real bounds (production: SwiftUI attaches + sizes):
        // the held state flushes and renders into the real viewport.
        let renderedNow = expectation(description: "rendered after sizing")
        controller.onRendered = { _ in renderedNow.fulfill() }
        controller.webView.setFrameSize(NSSize(width: 720, height: 600))
        wait(for: [renderedNow], timeout: 20)

        let ack = controller.lastRenderedAck
        XCTAssertEqual(ack?.generation, 1)
        XCTAssertEqual(ack?.viewportWidth ?? -1, 720, accuracy: 2)
        XCTAssertEqual(ack?.viewportHeight ?? -1, 600, accuracy: 2)
        let count = evaluate("document.querySelectorAll('[data-mi]').length", in: controller) as? Int
        XCTAssertEqual(count, 3)
        // The held text size flushed with the load.
        let size = evaluate("getComputedStyle(document.documentElement).getPropertyValue('--docsize').trim()", in: controller) as? String
        XCTAssertEqual(size, "15px")
    }

    // MARK: - Zero-viewport self-heal re-injects exactly once (§8.38(8))

    @MainActor
    func testZeroViewportAckWithRealBoundsSelfHealsExactlyOnce() {
        let controller = makeController() // sized: 720x600-class bounds
        var realRenders = 0
        let firstRender = expectation(description: "initial render")
        controller.onRendered = { [weak controller] _ in
            if (controller?.lastRenderedAck?.viewportHeight ?? -1) > 0 { realRenders += 1 }
            if realRenders == 1 { firstRender.fulfill() }
        }
        load(conversation("heal", count: 2), into: controller)
        wait(for: [firstRender], timeout: 20)
        XCTAssertEqual(realRenders, 1)

        // A pathological ack: zero viewport while the native bounds are
        // real (any future path that slips past the gate). The controller
        // must re-inject the latest load ONCE.
        let healed = expectation(description: "self-heal re-render")
        controller.onRendered = { [weak controller] _ in
            if (controller?.lastRenderedAck?.viewportHeight ?? -1) > 0 {
                realRenders += 1
                if realRenders == 2 { healed.fulfill() }
            }
        }
        _ = evaluate(
            "window.webkit.messageHandlers.shiibar.postMessage({type:'rendered', gen: 1, ms: 1, docH: 500, vw: 0, vh: 0}); 0",
            in: controller
        )
        wait(for: [healed], timeout: 20)
        XCTAssertEqual(realRenders, 2, "the self-heal must re-inject and produce one real render")

        // A second zero-viewport ack for the same generation: guarded — no
        // loop, no third render.
        _ = evaluate(
            "window.webkit.messageHandlers.shiibar.postMessage({type:'rendered', gen: 1, ms: 1, docH: 500, vw: 0, vh: 0}); 0",
            in: controller
        )
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(realRenders, 2, "the self-heal must fire at most once per generation")
    }

    // MARK: - WebContent process termination recovers with state replayed

    @MainActor
    func testProcessTerminationRecoveryReplaysTheLatestState() {
        let controller = makeController()
        let firstRender = expectation(description: "initial render")
        controller.onRendered = { _ in firstRender.fulfill() }
        let messages = conversation("recovered", count: 4)
        load(messages, into: controller)
        controller.setTextSize(16)
        wait(for: [firstRender], timeout: 20)

        // Simulate the WebContent process dying (the classic silently-blank
        // pane): drive the public delegate hook, which reloads the page and
        // replays the latest scripts.
        let reRender = expectation(description: "re-render after recovery")
        controller.onRendered = { _ in reRender.fulfill() }
        controller.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(controller.webView)
        wait(for: [reRender], timeout: 20)

        let probe = evaluate(
            "JSON.stringify({count: document.querySelectorAll('[data-mi]').length, size: getComputedStyle(document.documentElement).getPropertyValue('--docsize').trim()})",
            in: controller
        ) as? String ?? ""
        XCTAssertTrue(probe.contains(#""count":4"#), "the conversation must be back after recovery: \(probe)")
        XCTAssertTrue(probe.contains(#""size":"16px""#), "the text size must replay after recovery: \(probe)")
    }
}
