import ShiibarCcCore
import WebKit
import XCTest
@testable import ConversationsWebPaneKit

/// Keyboard scrolling of the message surface (DESIGN.md §4.5 "key
/// operations": on the one-column detail page ↑ / ↓ scroll the conversation,
/// like Space and Page Up / Page Down). The scroller is the inner `#doc`
/// element, which WebKit only scrolls from the keyboard while it (or
/// something inside it) is focused — the page focuses it on the first key
/// that arrives with nothing focused. By default the window is never
/// ordered on screen (see the investigation knobs below).
final class WebPaneKeyboardScrollTests: XCTestCase {
    // MARK: - Investigation knobs
    //
    // Read from the process environment; when absent the tests behave as
    // they do without them. By default the window is never ordered on
    // screen. The delay and the other window modes exist only for the CI
    // investigation job that measures when WebKit's keyboard scrolling
    // stops working in a window that is not shown.

    private enum DiagWindowMode: String {
        /// Never ordered on screen (the default).
        case hidden
        /// Ordered front before the page loads.
        case front
        /// Moved far off every screen, then ordered front before the page
        /// loads.
        case offscreen
        /// Fully transparent and click-through, then ordered front before
        /// the page loads: on screen for AppKit and WebKit, invisible to
        /// the person at the machine.
        case transparent
    }

    private static let diagEnvironment = ProcessInfo.processInfo.environment

    /// `KBSCROLL_DELAY_MS`: how long to spin the main run loop right before
    /// the first key of each test.
    private var diagDelayMs: Int {
        Self.diagEnvironment["KBSCROLL_DELAY_MS"].flatMap { Int($0) } ?? 0
    }

    /// `KBSCROLL_WINDOW`: `hidden` (default), `front`, `offscreen` or
    /// `transparent`.
    private var diagWindowMode: DiagWindowMode {
        Self.diagEnvironment["KBSCROLL_WINDOW"].flatMap { DiagWindowMode(rawValue: $0) } ?? .hidden
    }

    /// Spins the main run loop for `milliseconds`.
    @MainActor
    private func diagSpin(milliseconds: Int) {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
        while Date() < deadline {
            RunLoop.main.run(until: deadline)
        }
    }

    /// Spins the main run loop for the configured delay before the first
    /// key; does nothing when no delay is configured.
    @MainActor
    private func diagDelayBeforeFirstKey() {
        guard diagDelayMs > 0 else { return }
        diagSpin(milliseconds: diagDelayMs)
    }

    // MARK: - Crash diagnostics
    //
    // The test process sometimes aborts with "freed pointer was not the
    // last allocation" when a test method returns (XCTest's
    // TaskLocal.withValue frees from a Swift task allocator). These lines
    // record, unbuffered so they survive the abort, how far each test got
    // and whether a Swift task is current on the main thread at each step.

    override class func setUp() {
        super.setUp()
        setvbuf(stdout, nil, _IONBF, 0)
    }

    private func diagTask(_ step: String) {
        let hasTask = withUnsafeCurrentTask { $0 != nil }
        print("[kbscroll-crash] \(diagName) step=\(step) currentTask=\(hasTask) mainThread=\(Thread.isMainThread)")
    }

    @MainActor
    private func hostedController() -> (WebPaneController, NSWindow) {
        diagTask("setup-begin")
        let windowEnv = Self.diagEnvironment["KBSCROLL_WINDOW"].map { " windowEnv=\($0)" } ?? ""
        diagPrint("setup", "config delayMs=\(diagDelayMs) window=\(diagWindowMode.rawValue)\(windowEnv)")
        let controller = WebPaneController()
        controller.openExternalURL = { XCTFail("no test may open a URL: \($0)") }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("cc.shiibar.tests." + UUID().uuidString))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        controller.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        window.contentView?.addSubview(controller.webView)
        switch diagWindowMode {
        case .hidden:
            break
        case .front:
            window.orderFrontRegardless()
        case .offscreen:
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderFrontRegardless()
        case .transparent:
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
        }
        let rendered = expectation(description: "page rendered")
        controller.onRendered = { _ in rendered.fulfill() }
        let messages = (0..<30).map {
            ConversationMessage(seq: Int64($0), role: "assistant", text: "filler paragraph \($0)\n\nmore filler text to give the document height")
        }
        controller.load(messages: messages, rendered: messages.map { RenderedMessage(role: $0.role, text: $0.text) }, anchorSeq: nil)
        diagTask("setup-loaded")
        wait(for: [rendered], timeout: 20)
        diagTask("setup-rendered")
        XCTAssertTrue(window.makeFirstResponder(controller.webView))
        diagTask("setup-first-responder")
        installProbe(in: controller)
        diagTask("setup-end")
        return (controller, window)
    }

    // MARK: - Diagnostics
    //
    // Every run prints `[kbscroll-diag]` lines so that a rare CI failure of
    // the keyboard scroll can be compared with passing runs. They locate
    // where the key-to-scroll chain breaks: the native event not reaching
    // the web view, the JS keydown not firing, #doc not getting focus,
    // WebKit's default scrolling not happening, or page script undoing the
    // scroll. None of these helpers asserts anything, so they never change
    // a test's outcome.

    private var diagName: String {
        name.split(separator: " ").last.map { String($0.dropLast()) } ?? name
    }

    private func diagPrint(_ attempt: String, _ message: String) {
        print("[kbscroll-diag] \(diagName) attempt=\(attempt) \(message)")
    }

    /// Evaluates a script without failing the test on an error (a dead web
    /// content process is one of the possible causes); the error is
    /// printed instead.
    @MainActor
    private func diagEvaluate(_ script: String, in controller: WebPaneController, attempt: String) -> Any? {
        var output: Any?
        var finished = false
        controller.webView.evaluateJavaScript(script) { [self] result, error in
            if let error {
                diagPrint(attempt, "js-error: \(error)")
            }
            output = result
            finished = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        if !finished {
            diagPrint(attempt, "js-timeout: no reply in 10 s")
        }
        return output
    }

    /// Records key, scroll and focus events on the page into
    /// `window.__kbdiag`. The capture listeners on `window` run before the
    /// page's own capture listener on `document`; the bubble listener on
    /// `window` runs after every other listener and so sees
    /// `defaultPrevented` as final.
    @MainActor
    private func installProbe(in controller: WebPaneController) {
        let result = diagEvaluate("""
            (function() {
              if (window.__kbdiag) { return 'already installed'; }
              const doc = document.getElementById('doc');
              const d = {
                counts: { keydownCapture: 0, keyupCapture: 0, keydownBubble: 0, scroll: 0, focusin: 0, focusout: 0 },
                records: [],
                dropped: 0,
              };
              window.__kbdiag = d;
              const describe = el => el ? (el.tagName.toLowerCase() + (el.id ? '#' + el.id : '')) : 'null';
              const record = (type, e) => {
                const last = d.records[d.records.length - 1];
                if (type === 'scroll' && last && last.type === 'scroll') {
                  last.n += 1;
                  last.top = doc.scrollTop;
                  last.t = Math.round(performance.now());
                  return;
                }
                if (d.records.length >= 40) { d.dropped += 1; return; }
                d.records.push({
                  type: type,
                  key: e.key === undefined ? null : e.key,
                  prevented: e.defaultPrevented,
                  active: describe(document.activeElement),
                  top: doc ? doc.scrollTop : null,
                  t: Math.round(performance.now()),
                  n: 1,
                });
              };
              window.addEventListener('keydown', e => { d.counts.keydownCapture += 1; record('keydown-capture', e); }, true);
              window.addEventListener('keyup', e => { d.counts.keyupCapture += 1; record('keyup-capture', e); }, true);
              window.addEventListener('keydown', e => { d.counts.keydownBubble += 1; record('keydown-bubble', e); }, false);
              if (doc) { doc.addEventListener('scroll', e => { d.counts.scroll += 1; record('scroll', e); }); }
              document.addEventListener('focusin', e => { d.counts.focusin += 1; record('focusin', e); });
              document.addEventListener('focusout', e => { d.counts.focusout += 1; record('focusout', e); });
              return 'installed';
            })()
            """, in: controller, attempt: "setup")
        diagPrint("setup", "probe=\(result.map { "\($0)" } ?? "nil")")
    }

    /// Prints one line with the page state (as JSON) and one with the
    /// native window / responder state.
    @MainActor
    private func diagSnapshot(_ attempt: String, in controller: WebPaneController, window: NSWindow) {
        let page = diagEvaluate("""
            (function() {
              const doc = document.getElementById('doc');
              const describe = el => el ? (el.tagName.toLowerCase() + (el.id ? '#' + el.id : '')) : 'null';
              const sel = window.getSelection();
              return JSON.stringify({
                probe: window.__kbdiag || null,
                active: describe(document.activeElement),
                hasFocus: document.hasFocus(),
                visibility: document.visibilityState,
                scrollTop: doc ? doc.scrollTop : null,
                scrollHeight: doc ? doc.scrollHeight : null,
                clientHeight: doc ? doc.clientHeight : null,
                overflowY: doc ? getComputedStyle(doc).overflowY : null,
                selectionType: sel ? sel.type : null,
              });
            })()
            """, in: controller, attempt: attempt)
        diagPrint(attempt, "page=\(page.map { "\($0)" } ?? "nil")")

        let webView = controller.webView
        let responder = window.firstResponder
        let responderType = responder.map { String(describing: type(of: $0)) } ?? "nil"
        let responderIsWebView = responder === webView
        let responderInWebView = (responder as? NSView)?.isDescendant(of: webView) ?? false
        // Read without creating the shared application if no test made one.
        let app: NSApplication? = NSApp
        let keyWindow = app?.keyWindow
        let mainWindow = app?.mainWindow
        let native = [
            "firstResponder=\(responderType)",
            "firstResponderIsWebView=\(responderIsWebView)",
            "firstResponderInWebView=\(responderInWebView)",
            "isKeyWindow=\(window.isKeyWindow)",
            "isVisible=\(window.isVisible)",
            "occlusionState=\(window.occlusionState.rawValue)",
            "appExists=\(app != nil)",
            "appActive=\(app?.isActive ?? false)",
            "appKeyWindow=\(keyWindow == nil ? "nil" : (keyWindow === window ? "this" : "other"))",
            "appMainWindow=\(mainWindow == nil ? "nil" : (mainWindow === window ? "this" : "other"))",
            "appWindows=\(app?.windows.count ?? -1)",
            "webViewLoading=\(webView.isLoading)",
            "webViewHasWindow=\(webView.window != nil)",
            "webViewFrame=\(NSStringFromRect(webView.frame))",
            "windowFrame=\(NSStringFromRect(window.frame))",
            "screens=\(NSScreen.screens.count)",
        ].joined(separator: " ")
        diagPrint(attempt, "native: \(native)")
    }

    /// Counts `requestAnimationFrame` callbacks and 16 ms `setTimeout`
    /// callbacks in the page while the main run loop spins for 300 ms:
    /// shows whether WebKit still drives rendering updates (rAF) and
    /// whether the page's timers still run.
    @MainActor
    private func diagRefreshProbe(_ attempt: String, in controller: WebPaneController) {
        _ = diagEvaluate("""
            (function() {
              const p = { raf: 0, timeouts: 0, running: true, t0: performance.now() };
              window.__kbrefresh = p;
              const onFrame = () => { if (!p.running) { return; } p.raf += 1; requestAnimationFrame(onFrame); };
              const onTimeout = () => { if (!p.running) { return; } p.timeouts += 1; setTimeout(onTimeout, 16); };
              requestAnimationFrame(onFrame);
              setTimeout(onTimeout, 16);
              return 0;
            })()
            """, in: controller, attempt: attempt)
        diagSpin(milliseconds: 300)
        let result = diagEvaluate("""
            (function() {
              const p = window.__kbrefresh;
              if (!p) { return 'no refresh probe'; }
              p.running = false;
              return 'raf=' + p.raf + ' timeouts=' + p.timeouts + ' elapsedMs=' + Math.round(performance.now() - p.t0);
            })()
            """, in: controller, attempt: attempt)
        diagPrint(attempt, "refresh \(result.map { "\($0)" } ?? "nil")")
    }

    /// Reads `#doc.scrollTop` without asserting on the evaluation.
    @MainActor
    private func diagScrollTop(_ attempt: String, in controller: WebPaneController) -> Double {
        let value = diagEvaluate("document.getElementById('doc').scrollTop", in: controller, attempt: attempt)
        return (value as? Double) ?? (value as? Int).map(Double.init) ?? -1
    }

    /// Lets any keyboard scroll animation settle, then puts `#doc` back at
    /// `start` so the next probe starts from the same position.
    @MainActor
    private func diagReset(to start: Double, in controller: WebPaneController, attempt: String) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        _ = diagEvaluate("document.getElementById('doc').scrollTop = \(start); 0", in: controller, attempt: attempt)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        diagPrint(attempt, "reset scrollTop=\(diagScrollTop(attempt, in: controller)) (start=\(start))")
    }

    /// Runs on the failure path of `tapUntilScrollChanges` only, before
    /// the test's assertion fails: each probe bypasses one link of the
    /// key-to-scroll chain to show which link is broken.
    @MainActor
    private func diagFailureProbes(
        _ keyCode: UInt16, _ characters: String, from start: Double,
        in controller: WebPaneController, window: NSWindow
    ) {
        let delta = keyCode == 125 ? 40 : -40

        // 1. Programmatic scroll, read now and after a short run loop: does
        // #doc scroll at all, and does page script snap it back?
        let immediate = diagEvaluate("""
            (function() {
              const doc = document.getElementById('doc');
              const before = doc.scrollTop;
              doc.scrollBy({ top: \(delta), behavior: 'instant' });
              return JSON.stringify({ before: before, after: doc.scrollTop });
            })()
            """, in: controller, attempt: "probe1")
        diagPrint("probe1", "programmatic scrollBy(\(delta)) immediate=\(immediate.map { "\($0)" } ?? "nil")")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        diagPrint("probe1", "programmatic scrollBy(\(delta)) after 0.5 s scrollTop=\(diagScrollTop("probe1", in: controller))")
        diagReset(to: start, in: controller, attempt: "probe1")

        // 2. Focus #doc from the test: does a tap scroll once the scroller
        // is focused without relying on the page's keydown listener?
        let focused = diagEvaluate("""
            (function() {
              const doc = document.getElementById('doc');
              doc.focus({ preventScroll: true });
              const el = document.activeElement;
              return el ? (el.tagName.toLowerCase() + (el.id ? '#' + el.id : '')) : 'null';
            })()
            """, in: controller, attempt: "probe2")
        diagPrint("probe2", "explicit focus, activeElement=\(focused.map { "\($0)" } ?? "nil")")
        press(keyCode, characters, in: controller, window: window)
        let afterFocus = waitForScrollChange(from: start, in: controller)
        diagPrint("probe2", "tap after explicit focus scrollTop=\(afterFocus) scrolled=\(afterFocus != start)")
        diagSnapshot("probe2", in: controller, window: window)
        if afterFocus != start { diagReset(to: start, in: controller, attempt: "probe2") }

        // 3. Make the web view first responder again: was the native
        // responder chain the broken link?
        let madeFirstResponder = window.makeFirstResponder(controller.webView)
        diagPrint("probe3", "makeFirstResponder(webView)=\(madeFirstResponder)")
        press(keyCode, characters, in: controller, window: window)
        let afterResponder = waitForScrollChange(from: start, in: controller)
        diagPrint("probe3", "tap after makeFirstResponder scrollTop=\(afterResponder) scrolled=\(afterResponder != start)")
        diagSnapshot("probe3", in: controller, window: window)
        if afterResponder != start { diagReset(to: start, in: controller, attempt: "probe3") }

        // 4. Deliver the key through the window's event dispatch instead of
        // calling the web view directly.
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)!
            window.sendEvent(event)
            if type == .keyDown {
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            }
        }
        let afterSendEvent = waitForScrollChange(from: start, in: controller)
        diagPrint("probe4", "tap via window.sendEvent scrollTop=\(afterSendEvent) scrolled=\(afterSendEvent != start)")
        if afterSendEvent != start { diagReset(to: start, in: controller, attempt: "probe4") }

        // Rendering updates and timers after the probes, with the window
        // still as configured.
        diagRefreshProbe("probes-end", in: controller)

        // 5. Show the window: does that revive keyboard scrolling in a page
        // where it had stopped?
        window.orderFrontRegardless()
        diagSpin(milliseconds: 500)
        diagRefreshProbe("probe5", in: controller)
        press(keyCode, characters, in: controller, window: window)
        let afterShow = waitForScrollChange(from: start, in: controller)
        diagPrint("probe5", "tap after orderFrontRegardless scrollTop=\(afterShow) scrolled=\(afterShow != start)")
        window.orderOut(nil)

        // Final state.
        diagSnapshot("final", in: controller, window: window)
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

    /// Taps the key until `#doc.scrollTop` differs from `start`, or the
    /// attempts run out. The web content process can drop a synthesized key
    /// that arrives while it is still settling after the render, so one tap
    /// is not guaranteed to scroll on a slow machine.
    @MainActor
    private func tapUntilScrollChanges(
        _ keyCode: UInt16, _ characters: String, from start: Double,
        in controller: WebPaneController, window: NSWindow
    ) -> Double {
        var current = start
        diagDelayBeforeFirstKey()
        diagSnapshot("0", in: controller, window: window)
        for attempt in 1...5 {
            press(keyCode, characters, in: controller, window: window)
            current = waitForScrollChange(from: start, in: controller)
            diagPrint("\(attempt)", "scrollTop=\(current) start=\(start) scrolled=\(current != start)")
            diagSnapshot("\(attempt)", in: controller, window: window)
            if attempt == 1 {
                diagRefreshProbe("1", in: controller)
            }
            if current != start { break }
        }
        if current == start {
            diagPrint("exhausted", "no scroll after 5 taps; running failure probes")
            diagFailureProbes(keyCode, characters, from: start, in: controller, window: window)
        }
        return current
    }

    @MainActor
    func testUpArrowWithNothingFocusedScrollsTheConversation() {
        diagTask("test-begin")
        defer { diagTask("test-end") }
        let (controller, window) = hostedController()
        defer { window.close() }
        let start = scrollTop(controller)
        XCTAssertGreaterThan(start, 0, "the page opens at the bottom (latest)")
        XCTAssertEqual(evaluate("document.activeElement === document.body", in: controller) as? Bool, true)

        XCTAssertLessThan(tapUntilScrollChanges(126, "\u{F700}", from: start, in: controller, window: window), start)
    }

    @MainActor
    func testDownArrowScrollsTheConversation() {
        diagTask("test-begin")
        defer { diagTask("test-end") }
        let (controller, window) = hostedController()
        defer { window.close() }
        _ = evaluate("document.getElementById('doc').scrollTop = 0; 0", in: controller)
        XCTAssertGreaterThan(tapUntilScrollChanges(125, "\u{F701}", from: 0, in: controller, window: window), 0)
    }

    /// Focusing the scroller on a key must not touch the page's selection
    /// (§4.6: the selection is what copy acts on).
    @MainActor
    func testArrowKeepsTheSelection() {
        diagTask("test-begin")
        defer { diagTask("test-end") }
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
        diagDelayBeforeFirstKey()
        diagSnapshot("0", in: controller, window: window)
        press(126, "\u{F700}", in: controller, window: window)
        let current = waitForScrollChange(from: start, in: controller)
        // Not asserted: this test is about the selection only.
        diagPrint("1", "scrollTop=\(current) start=\(start) scrolled=\(current != start)")
        diagSnapshot("1", in: controller, window: window)
        diagRefreshProbe("1", in: controller)
        XCTAssertEqual(evaluate("window.getSelection().toString()", in: controller) as? String, selected)
    }
}
