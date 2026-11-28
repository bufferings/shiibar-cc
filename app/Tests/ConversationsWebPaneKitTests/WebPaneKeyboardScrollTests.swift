import ShiibarCcCore
import WebKit
import XCTest
@testable import ConversationsWebPaneKit

/// Keyboard scrolling of the message surface (DESIGN.md §4.5 "key
/// operations": on the one-column detail page ↑ / ↓ scroll the conversation,
/// like Space and Page Up / Page Down). The scroller is the inner `#doc`
/// element, which WebKit only scrolls from the keyboard while it (or
/// something inside it) is focused — the page focuses it on the first key
/// that arrives with nothing focused. The window is ordered on screen, fully
/// transparent and click-through, because WebKit does not run the keyboard
/// scroll animation in a window that is not on screen; ordering it front with
/// `orderFrontRegardless()` does not activate the app.
final class WebPaneKeyboardScrollTests: XCTestCase {
    @MainActor
    private func hostedController() -> (WebPaneController, NSWindow) {
        let controller = WebPaneController()
        controller.openExternalURL = { XCTFail("no test may open a URL: \($0)") }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("cc.shiibar.tests." + UUID().uuidString))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        controller.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        window.contentView?.addSubview(controller.webView)
        window.orderFrontRegardless()
        let rendered = renderExpectation(description: "page rendered")
        controller.onRendered = { _ in rendered.fulfill() }
        let messages = (0..<30).map {
            ConversationMessage(seq: Int64($0), role: "assistant", text: "filler paragraph \($0)\n\nmore filler text to give the document height")
        }
        controller.load(messages: messages, rendered: messages.map { RenderedMessage(role: $0.role, text: $0.text) }, anchorSeq: nil)
        wait(for: [rendered], timeout: 20)
        XCTAssertTrue(window.makeFirstResponder(controller.webView))
        return (controller, window)
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
    private func scrollTop(_ controller: WebPaneController) -> Double {
        let value = evaluate("document.getElementById('doc').scrollTop", in: controller)
        return (value as? Double) ?? (value as? Int).map(Double.init) ?? -1
    }

    @MainActor
    private func press(_ keyCode: UInt16, _ characters: String, in controller: WebPaneController, window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)!
            if type == .keyDown {
                controller.webView.keyDown(with: event)
                // A real tap: the key is released a moment later (WebKit's
                // keyboard scrolling animates until the key goes up).
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            } else {
                controller.webView.keyUp(with: event)
            }
        }
    }

    /// Polls until `#doc.scrollTop` differs from `start` (keyboard scrolling
    /// animates), or the timeout passes.
    @MainActor
    private func waitForScrollChange(from start: Double, in controller: WebPaneController) -> Double {
        let deadline = Date().addingTimeInterval(5)
        var current = scrollTop(controller)
        while current == start, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            current = scrollTop(controller)
        }
        return current
    }

    @MainActor
    func testUpArrowWithNothingFocusedScrollsTheConversation() {
        let (controller, window) = hostedController()
        defer { window.close() }
        let start = scrollTop(controller)
        XCTAssertGreaterThan(start, 0, "the page opens at the bottom (latest)")
        XCTAssertEqual(evaluate("document.activeElement === document.body", in: controller) as? Bool, true)

        press(126, "\u{F700}", in: controller, window: window)
        XCTAssertLessThan(waitForScrollChange(from: start, in: controller), start)
    }

    @MainActor
    func testDownArrowScrollsTheConversation() {
        let (controller, window) = hostedController()
        defer { window.close() }
        _ = evaluate("document.getElementById('doc').scrollTop = 0; 0", in: controller)
        press(125, "\u{F701}", in: controller, window: window)
        XCTAssertGreaterThan(waitForScrollChange(from: 0, in: controller), 0)
    }

    /// Focusing the scroller on a key must not touch the page's selection
    /// (§4.6: the selection is what copy acts on).
    @MainActor
    func testArrowKeepsTheSelection() {
        let (controller, window) = hostedController()
        defer { window.close() }
        let selected = evaluate("""
            (function() {
              const p = document.querySelector('#doc p');
              const r = document.createRange();
              r.selectNodeContents(p);
              const s = window.getSelection();
              s.removeAllRanges();
              s.addRange(r);
              return s.toString();
            })()
            """, in: controller) as? String
        XCTAssertFalse((selected ?? "").isEmpty)
        let start = scrollTop(controller)
        press(126, "\u{F700}", in: controller, window: window)
        _ = waitForScrollChange(from: start, in: controller)
        XCTAssertEqual(evaluate("window.getSelection().toString()", in: controller) as? String, selected)
    }
}
