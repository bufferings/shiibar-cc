import AppKit
import ShiibarCcCore
import WebKit
import XCTest
@testable import ConversationsWebPaneKit

/// End-to-end copy-shortcut tests (DESIGN.md §4.6/§8.38(5), M39 T3): a
/// synthesized key event drives `performKeyEquivalent` and the assertion is
/// on the INJECTED pasteboard's content — the lesson of two smoke rounds is
/// that testing menu structure or the JS pipeline alone never proves the
/// key actually copies. This app has no Edit menu (§4.5), so the pane's own
/// key handling is the only ⌘C route that exists.
final class WebPaneCopyShortcutTests: XCTestCase {
    // MARK: - Harness plumbing (same discipline as WebPaneSecurityTests:
    // named pasteboards, spied external opens, no outside-sandbox effects)

    @MainActor
    private func loadedController(_ messages: [ConversationMessage]) -> WebPaneController {
        let controller = WebPaneController()
        controller.openExternalURL = { XCTFail("no test may open a URL: \($0)") }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("cc.shiibar.tests." + UUID().uuidString))
        controller.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 800)
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

    /// Select the whole first message body and wait until the bridge has
    /// reported the selection to the controller (the ⌘C guard reads it).
    @MainActor
    private func selectFirstMessage(in controller: WebPaneController) {
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
        waitForSelectionState(true, in: controller)
    }

    @MainActor
    private func waitForSelectionState(_ expected: Bool, in controller: WebPaneController) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, controller.pageHasSelection != expected {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(controller.pageHasSelection, expected, "selection state never reached the bridge")
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

    /// A synthesized ⌘-key keyDown, the same shape AppKit dispatches.
    private func keyEvent(charactersIgnoringModifiers: String, characters: String, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false, keyCode: 8 // ANSI C
        )!
    }

    private var commandC: NSEvent {
        keyEvent(charactersIgnoringModifiers: "c", characters: "c", flags: [.command])
    }

    private var shiftCommandC: NSEvent {
        keyEvent(charactersIgnoringModifiers: "C", characters: "c", flags: [.command, .shift])
    }

    // MARK: - (a) cmd-C: key press -> WebKit's copy: dispatch (§8.38(6):
    // the verification point is that the key REACHES the dispatch; WebKit's
    // own clipboard writing — rich formats included — is not re-tested)

    @MainActor
    func testCommandCReachesTheWebKitCopyDispatch() {
        let messages = [
            ConversationMessage(seq: 1, role: "assistant", text: "plain **bold** words"),
        ]
        let controller = loadedController(messages)
        var dispatched = 0
        controller.dispatchCopy = { dispatched += 1 }
        selectFirstMessage(in: controller)

        let handled = controller.webView.performKeyEquivalent(with: commandC)
        XCTAssertTrue(handled, "cmd-C with a selection must be handled by the pane")
        XCTAssertEqual(dispatched, 1, "the key must reach the copy: dispatch exactly once")
        // Nothing goes through OUR pasteboard path for plain Copy.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(controller.pasteboard.string(forType: .string))
    }

    // MARK: - (b) shift-cmd-C: key press -> Markdown serialization

    @MainActor
    func testShiftCommandCCopiesTheMarkdownSerialization() {
        let messages = [
            ConversationMessage(seq: 1, role: "assistant", text: "# Title\n\nplain **bold** words"),
        ]
        let controller = loadedController(messages)
        selectFirstMessage(in: controller)

        let handled = controller.webView.performKeyEquivalent(with: shiftCommandC)
        XCTAssertTrue(handled, "shift-cmd-C must be handled by the pane")
        XCTAssertEqual(
            waitForPasteboardString(controller.pasteboard),
            "# Title\n\nplain **bold** words",
            "the selection must serialize back to Markdown"
        )
    }

    // MARK: - (c) without a selection BOTH shortcuts fall through
    // (§8.38(6): copying is selection-only — nothing to copy, nothing
    // handled, nothing written)

    @MainActor
    func testShortcutsWithoutSelectionFallThroughAndWriteNothing() {
        let messages = [
            ConversationMessage(seq: 1, role: "assistant", text: "nothing selected here"),
        ]
        let controller = loadedController(messages)
        var dispatched = 0
        controller.dispatchCopy = { dispatched += 1 }
        _ = evaluate("getSelection().removeAllRanges(); 0", in: controller)
        waitForSelectionState(false, in: controller)

        XCTAssertFalse(controller.webView.performKeyEquivalent(with: commandC),
                       "cmd-C without a selection must fall through")
        XCTAssertFalse(controller.webView.performKeyEquivalent(with: shiftCommandC),
                       "shift-cmd-C without a selection must fall through")
        // Give any stray async write a chance to land before asserting.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(dispatched, 0, "the copy: dispatch must not fire")
        XCTAssertNil(controller.pasteboard.string(forType: .string), "nothing may be written")
    }

    // MARK: - (c2) with the Edit menu back (§8.41), the pane claims the
    // copy keys only while it owns first responder — a search-field edit
    // must reach Edit > Copy, not the pane's stale page selection

    @MainActor
    func testCommandCFallsThroughWhenAnotherViewOwnsFocus() {
        let messages = [
            ConversationMessage(seq: 1, role: "assistant", text: "selectable page text"),
        ]
        let controller = loadedController(messages)
        selectFirstMessage(in: controller) // the page HAS a selection
        var dispatched = 0
        controller.dispatchCopy = { dispatched += 1 }

        // Host the pane beside a text field in an (offscreen, never shown)
        // window and hand focus to the field.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let field = NSTextField(frame: NSRect(x: 0, y: 560, width: 300, height: 24))
        controller.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        container.addSubview(field)
        container.addSubview(controller.webView)
        window.contentView = container
        window.makeFirstResponder(field)

        XCTAssertFalse(controller.webView.performKeyEquivalent(with: commandC),
                       "the pane must not steal cmd-C from the focused field")
        XCTAssertFalse(controller.webView.performKeyEquivalent(with: shiftCommandC))
        XCTAssertEqual(dispatched, 0)

        // Focus handed to the pane: it claims the key again.
        window.makeFirstResponder(controller.webView)
        XCTAssertTrue(controller.webView.performKeyEquivalent(with: commandC))
        XCTAssertEqual(dispatched, 1)
        window.orderOut(nil)
    }

    // MARK: - (d) the context menu is exactly the two copy verbs

    @MainActor
    func testContextMenuWithSelectionShowsTheTwoVerbsEnabled() {
        let controller = loadedController([
            ConversationMessage(seq: 1, role: "assistant", text: "text"),
        ])
        selectFirstMessage(in: controller)

        // A menu shaped like WebKit's (typical items around its Copy).
        let menu = NSMenu()
        let systemCopy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        systemCopy.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")
        menu.addItem(NSMenuItem(title: "Look Up selection", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Translate selection", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(systemCopy)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Search with the default engine", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Share", action: nil, keyEquivalent: ""))

        let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        controller.webView.willOpenMenu(menu, with: rightClick)

        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Copy as Markdown"],
                       "the reading surface offers exactly two verbs (§4.6)")
        XCTAssertTrue(menu.items[0] === systemCopy, "WebKit's own Copy item is reused, never duplicated")
        XCTAssertEqual(menu.items[0].keyEquivalent, "c")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [.command])
        XCTAssertEqual(menu.items[1].keyEquivalent, "C")
        XCTAssertEqual(menu.items[1].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertNotNil(menu.items[1].action, "Copy as Markdown is enabled with a selection")
    }

    @MainActor
    func testContextMenuWithoutSelectionShowsTheSameTwoVerbsDisabled() {
        let controller = loadedController([
            ConversationMessage(seq: 1, role: "assistant", text: "text"),
        ])
        _ = evaluate("getSelection().removeAllRanges(); 0", in: controller)
        waitForSelectionState(false, in: controller)

        // No selection -> WebKit provides no Copy item at all; the pane
        // still shows both verbs, disabled (§4.6/§8.38(6): round 1's
        // "disabled item swallows cmd-C" was really the missing Edit menu —
        // keys never route through this menu).
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Look Up selection", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        controller.webView.willOpenMenu(menu, with: rightClick)
        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Copy as Markdown"])
        XCTAssertNil(menu.items[0].action, "the placeholder Copy stays disabled")
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertNil(menu.items[1].action, "Copy as Markdown is disabled without a selection")
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertEqual(menu.items[0].keyEquivalent, "c")
        XCTAssertEqual(menu.items[1].keyEquivalent, "C")
    }
}
