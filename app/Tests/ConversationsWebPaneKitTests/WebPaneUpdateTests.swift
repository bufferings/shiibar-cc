import AppKit
import ShiibarCcCore
import WebKit
import XCTest
@testable import ConversationsWebPaneKit

/// The page side of the conversation pane reload (DESIGN.md §4.6
/// "conversation pane reload": applying the result, scrolling, hits) on a
/// live page: an appending update keeps the existing elements and their
/// state, the end-marker rule decides the scroll, a full re-render keeps the
/// top message in place, and the update is a generation-checked delivery
/// (§8.38(7)). Same sandbox discipline as the other kit tests: named
/// pasteboards, external opens fail the test.
final class WebPaneUpdateTests: XCTestCase {
    // MARK: - Harness

    @MainActor
    private func makeController(height: CGFloat = 600) -> WebPaneController {
        let controller = WebPaneController()
        controller.openExternalURL = { XCTFail("no test may open a URL: \($0)") }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("cc.shiibar.tests." + UUID().uuidString))
        controller.webView.frame = NSRect(x: 0, y: 0, width: 720, height: height)
        return controller
    }

    private func rendered(_ messages: [ConversationMessage]) -> [RenderedMessage] {
        messages.map { RenderedMessage(role: $0.role, text: $0.text) }
    }

    @MainActor
    private func load(_ messages: [ConversationMessage], into controller: WebPaneController, elapsed: String? = "5m") {
        let done = expectation(description: "loaded")
        controller.onRendered = { _ in done.fulfill() }
        controller.load(messages: messages, rendered: rendered(messages), anchorSeq: nil, elapsed: elapsed)
        wait(for: [done], timeout: 20)
    }

    /// Apply `messages` as an update, with Core's comparison against
    /// `displayed`, and wait for the page's ack.
    @MainActor
    private func update(
        from displayed: [ConversationMessage], to messages: [ConversationMessage],
        in controller: WebPaneController, elapsed: String? = "1m"
    ) {
        let change = ConversationPaneUpdate.classify(displayed: displayed, fetched: messages)
        let done = expectation(description: "updated")
        controller.onRendered = { _ in done.fulfill() }
        controller.update(messages: messages, rendered: rendered(messages), change: change, elapsed: elapsed)
        wait(for: [done], timeout: 20)
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
    private func number(_ script: String, in controller: WebPaneController) -> Double {
        (evaluate(script, in: controller) as? NSNumber)?.doubleValue ?? .nan
    }

    @MainActor
    private func waitForJS(_ script: String, toEqual expected: String, in controller: WebPaneController,
                           timeout: TimeInterval = 10) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        while Date() < deadline {
            last = evaluate(script, in: controller) as? String
            if last == expected { return last }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return last
    }

    @MainActor
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    /// `count` messages alternating user / assistant, each several lines
    /// long so the conversation is taller than the viewport.
    private func conversation(_ count: Int, from start: Int = 0) -> [ConversationMessage] {
        (start..<(start + count)).map { index in
            ConversationMessage(
                seq: Int64(index), role: index % 2 == 0 ? "user" : "assistant",
                text: "message \(index) " + String(repeating: "words in a line ", count: 30))
        }
    }

    private let atBottom = "Math.abs(doc.scrollTop + doc.clientHeight - doc.scrollHeight) <= 1"

    // MARK: - Appending

    @MainActor
    func testAppendingKeepsTheExistingElementsTheExpansionAndTheCopyFeedback() {
        let long = String(repeating: "filler words ", count: 60)
        let first = [
            ConversationMessage(seq: 1, role: "user", text: "first question"),
            ConversationMessage(seq: 2, role: "assistant", text: long),
        ]
        let controller = makeController()
        load(first, into: controller)
        controller.copyFeedbackSeconds = 30
        // Expand the folded reply, copy the question, and select some text.
        _ = evaluate("document.querySelector('.expand').click(); 0", in: controller)
        _ = evaluate("document.querySelectorAll('.cp')[0].click(); 0", in: controller)
        XCTAssertEqual(waitForJS("document.querySelectorAll('.cp')[0].dataset.state", toEqual: "done", in: controller), "done")
        _ = evaluate(
            """
            (function() {
              document.querySelectorAll('[data-mi]').forEach(el => { el.dataset.probe = 'kept'; });
              const mt = document.querySelector('.mt').firstChild;
              getSelection().setBaseAndExtent(mt, 0, mt, 5);
              return 0;
            })()
            """,
            in: controller)

        let second = first + [
            ConversationMessage(seq: 3, role: "user", text: "next question"),
            ConversationMessage(seq: 4, role: "assistant", text: "next answer"),
        ]
        update(from: first, to: second, in: controller)
        let probe = evaluate(
            """
            JSON.stringify({
              probes: Array.from(document.querySelectorAll('[data-mi]')).map(el => el.dataset.probe || 'new'),
              expand: document.querySelector('.expand').textContent,
              copied: Array.from(document.querySelectorAll('.cp')).map(b => b.dataset.state),
              selection: shiibarAPI.selectionRanges(),
              endcaps: document.querySelectorAll('.endcap').length,
              last: document.getElementById('doc').lastElementChild.className,
              endcap: document.querySelector('.endcap').textContent
            })
            """,
            in: controller) as? String
        XCTAssertEqual(
            probe,
            #"{"probes":["kept","kept","new","new"],"expand":"Show less","copied":["done","idle","idle","idle"],"#
                + #""selection":[{"m":0,"s":0,"l":5}],"endcaps":1,"last":"endcap","endcap":"Latest message · 1m ago"}"#)
    }

    @MainActor
    func testAppendingWhileTheEndMarkerIsInViewScrollsToTheNewEnd() {
        let first = conversation(12)
        let controller = makeController()
        load(first, into: controller)
        XCTAssertEqual(evaluate(atBottom, in: controller) as? Bool, true, "a first load starts at the end")
        update(from: first, to: first + conversation(4, from: 12), in: controller)
        XCTAssertEqual(evaluate(atBottom, in: controller) as? Bool, true)
        XCTAssertEqual(evaluate("document.querySelectorAll('[data-mi]').length", in: controller) as? Int, 16)
    }

    @MainActor
    func testAppendingWhileReadingEarlierMessagesKeepsTheScroll() {
        let first = conversation(12)
        let controller = makeController()
        load(first, into: controller)
        _ = evaluate("doc.scrollTop = 300; 0", in: controller)
        settle()
        XCTAssertEqual(evaluate("endMarkerInView()", in: controller) as? Bool, false)
        update(from: first, to: first + conversation(4, from: 12), in: controller)
        XCTAssertEqual(number("doc.scrollTop", in: controller), 300)
    }

    @MainActor
    func testAnEndMarkerOnlyPartlyInViewStillFollowsTheEnd() {
        let first = conversation(12)
        let controller = makeController()
        load(first, into: controller)
        // Leave only the top 2 points of the end marker inside the viewport.
        _ = evaluate(
            """
            (function() {
              const cap = document.querySelector('.endcap');
              doc.scrollTop = contentY(cap) + 2 - doc.clientHeight;
              return 0;
            })()
            """,
            in: controller)
        settle()
        XCTAssertEqual(evaluate(atBottom, in: controller) as? Bool, false)
        XCTAssertEqual(evaluate("endMarkerInView()", in: controller) as? Bool, true)
        update(from: first, to: first + conversation(2, from: 12), in: controller)
        XCTAssertEqual(evaluate(atBottom, in: controller) as? Bool, true)
    }

    /// Unchanged messages never move the scroll, even with the end marker
    /// partly in view.
    @MainActor
    func testUnchangedMessagesKeepTheScrollWithTheEndMarkerPartlyInView() {
        let messages = conversation(12)
        let controller = makeController()
        load(messages, into: controller)
        _ = evaluate(
            """
            (function() {
              const cap = document.querySelector('.endcap');
              doc.scrollTop = contentY(cap) + 2 - doc.clientHeight;
              return 0;
            })()
            """,
            in: controller)
        settle()
        XCTAssertEqual(evaluate("endMarkerInView()", in: controller) as? Bool, true)
        let before = number("doc.scrollTop", in: controller)
        update(from: messages, to: messages, in: controller, elapsed: "2m")
        XCTAssertEqual(number("doc.scrollTop", in: controller), before)
    }

    @MainActor
    func testTheMinimapCoversTheAppendedMessages() {
        let first = conversation(4)
        let controller = makeController()
        load(first, into: controller)
        let before = number("document.querySelectorAll('#mm .m').length", in: controller)
        update(from: first, to: first + conversation(2, from: 4), in: controller)
        let after = number("document.querySelectorAll('#mm .m').length", in: controller)
        XCTAssertGreaterThan(after, before)
    }

    @MainActor
    func testHitsAndBadgesFollowTheUpdatedMessages() {
        let long = String(repeating: "filler words ", count: 60)
        let first = [ConversationMessage(seq: 1, role: "user", text: "find needle")]
        let second = first + [ConversationMessage(seq: 2, role: "assistant", text: long + " needle needle")]
        let controller = makeController()
        load(first, into: controller)
        update(from: first, to: second, in: controller)
        let texts = rendered(second).map(\.renderedText)
        let hits = ConversationHits.locations(messageTexts: texts, terms: ["needle"])
        XCTAssertEqual(hits.count, 3)
        let applied = expectation(description: "hits applied")
        controller.onHitsApplied = { _ in applied.fulfill() }
        controller.setHits(hits, rendered: rendered(second), current: 0)
        wait(for: [applied], timeout: 10)
        let probe = evaluate(
            """
            JSON.stringify({
              badge: document.querySelector('.expand .cnt') ? document.querySelector('.expand .cnt').textContent : null,
              lines: document.querySelectorAll('#mm .hit').length,
              painted: CSS.highlights.get('shiibar-hit').size + CSS.highlights.get('shiibar-hit-current').size
            })
            """,
            in: controller) as? String
        // The two hits behind the fold count on the badge; one hit is painted.
        XCTAssertEqual(probe, #"{"badge":"2 matches","lines":3,"painted":1}"#)
    }

    // MARK: - The same messages

    @MainActor
    func testTheSameMessagesOnlyRelabelTheEndMarker() {
        let messages = conversation(6)
        let controller = makeController()
        load(messages, into: controller, elapsed: "5m")
        _ = evaluate("document.querySelectorAll('[data-mi]').forEach(el => { el.dataset.probe = 'kept'; }); doc.scrollTop = 200; 0",
                     in: controller)
        settle()
        update(from: messages, to: messages, in: controller, elapsed: "2m")
        let probe = evaluate(
            """
            JSON.stringify({
              kept: Array.from(document.querySelectorAll('[data-mi]')).every(el => el.dataset.probe === 'kept'),
              endcap: document.querySelector('.endcap').textContent,
              top: doc.scrollTop
            })
            """,
            in: controller) as? String
        XCTAssertEqual(probe, #"{"kept":true,"endcap":"Latest message · 2m ago","top":200}"#)
    }

    // MARK: - Rendering again

    @MainActor
    func testRenderingAgainKeepsTheTopMessageWhereItWas() {
        let first = conversation(20)
        let controller = makeController()
        load(first, into: controller)
        // Message 10 at the top, scrolled 5 points past its top edge.
        _ = evaluate("doc.scrollTop = contentY(document.querySelector('[data-seq=\"10\"]')) + 5; 0", in: controller)
        settle()
        XCTAssertEqual(evaluate("endMarkerInView()", in: controller) as? Bool, false)
        // The first message went away and message 15 changed: rendered again,
        // message 10 now sits at index 9.
        var second = Array(first.dropFirst())
        second[14] = ConversationMessage(seq: 15, role: second[14].role, text: "changed")
        update(from: first, to: second, in: controller)
        let offset = number("contentY(document.querySelector('[data-seq=\"10\"]')) - doc.scrollTop", in: controller)
        XCTAssertEqual(offset, -5, accuracy: 1)
        XCTAssertEqual(evaluate("document.querySelector('[data-seq=\"10\"]').dataset.mi", in: controller) as? String, "9")
    }

    @MainActor
    func testRenderingAgainWithoutTheTopMessageGoesToTheEnd() {
        let first = conversation(20)
        let controller = makeController()
        load(first, into: controller)
        _ = evaluate("doc.scrollTop = contentY(document.querySelector('[data-seq=\"10\"]')) + 5; 0", in: controller)
        settle()
        var second = first
        second[10] = ConversationMessage(seq: 10, role: first[10].role, text: "changed")
        update(from: first, to: second, in: controller)
        XCTAssertEqual(evaluate(atBottom, in: controller) as? Bool, true)
    }

    @MainActor
    func testRenderingAgainDropsTheExpansion() {
        let long = String(repeating: "filler words ", count: 60)
        let first = [
            ConversationMessage(seq: 1, role: "user", text: "question"),
            ConversationMessage(seq: 2, role: "assistant", text: long),
        ]
        let controller = makeController()
        load(first, into: controller)
        _ = evaluate("document.querySelector('.expand').click(); 0", in: controller)
        XCTAssertEqual(evaluate("document.querySelector('.expand').textContent", in: controller) as? String, "Show less")
        let second = [ConversationMessage(seq: 1, role: "user", text: "edited question"), first[1]]
        update(from: first, to: second, in: controller)
        XCTAssertEqual(evaluate("document.querySelector('.expand').textContent", in: controller) as? String,
                       "Show full message")
    }

    // MARK: - Delivery (§8.38(7))

    @MainActor
    func testARepeatedUpdateOnlyAcksAgain() {
        let first = conversation(2)
        let controller = makeController()
        load(first, into: controller)
        update(from: first, to: first + conversation(1, from: 2), in: controller)
        let generation = controller.lastRenderedAck?.generation ?? -1
        // The same delivery once more (a re-injection): nothing is added.
        let payload = "{\"messages\":[],\"elapsed\":null}"
        let acked = expectation(description: "acked again")
        controller.onRendered = { _ in acked.fulfill() }
        _ = evaluate("shiibarAPI.update(\(payload), 'append', 3, [], \(generation), \(generation - 1)); 0", in: controller)
        wait(for: [acked], timeout: 10)
        XCTAssertEqual(evaluate("document.querySelectorAll('[data-mi]').length", in: controller) as? Int, 3)
        XCTAssertEqual(controller.lastRenderedAck?.generation, generation)
    }

    /// Drops the page's next `update` call (a delivery that never reached
    /// the page): no DOM change and no ack.
    @MainActor
    private func dropNextUpdate(in controller: WebPaneController) {
        _ = evaluate(
            "(function() { const real = shiibarAPI.update; shiibarAPI.update = function() { shiibarAPI.update = real; }; return 0; })()",
            in: controller)
    }

    /// An update computed against a delivery the page never rendered is not
    /// applied on the wrong base: the latest content loads in full with the
    /// reader's top message where it was, not at the end.
    @MainActor
    func testAnUpdateAfterALostDeliveryKeepsTheReadersPosition() {
        let first = conversation(20)
        let controller = makeController()
        load(first, into: controller)
        _ = evaluate("doc.scrollTop = contentY(document.querySelector('[data-seq=\"10\"]')) + 5; 0", in: controller)
        settle()
        let second = first + conversation(2, from: 20)
        dropNextUpdate(in: controller)
        controller.update(messages: second, rendered: rendered(second),
                          change: ConversationPaneUpdate.classify(displayed: first, fetched: second), elapsed: "1m")
        settle()
        let third = second + conversation(2, from: 22)
        update(from: second, to: third, in: controller)
        XCTAssertEqual(evaluate("document.querySelectorAll('[data-mi]').length", in: controller) as? Int, 24)
        XCTAssertEqual(evaluate(atBottom, in: controller) as? Bool, false, "the reader is not thrown to the end")
        let offset = number("contentY(document.querySelector('[data-seq=\"10\"]')) - doc.scrollTop", in: controller)
        XCTAssertEqual(offset, 0, accuracy: 6, "message 10 is still at the top")
    }

    /// After an update, a recovery (here a WebContent restart) replays a
    /// full load of the updated content at the remembered anchor.
    @MainActor
    func testARecoveryAfterAnUpdateRestoresTheAnchor() {
        let first = conversation(20)
        let controller = makeController()
        load(first, into: controller)
        _ = evaluate("doc.scrollTop = contentY(document.querySelector('[data-seq=\"10\"]')) + 5; 0", in: controller)
        // Past the page's anchor report delay.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let second = first + conversation(2, from: 20)
        update(from: first, to: second, in: controller)

        let reloaded = expectation(description: "replayed")
        controller.onRendered = { _ in reloaded.fulfill() }
        controller.recoverFromProcessTermination()
        wait(for: [reloaded], timeout: 20)
        XCTAssertEqual(evaluate("document.querySelectorAll('[data-mi]').length", in: controller) as? Int, 22)
        XCTAssertEqual(evaluate(atBottom, in: controller) as? Bool, false)
        let offset = number("contentY(document.querySelector('[data-seq=\"10\"]')) - doc.scrollTop", in: controller)
        XCTAssertEqual(offset, 0, accuracy: 1, "the anchor message is at the top")
    }

    // MARK: - `Copied` (§4.6 "per-message copy", §9)

    @MainActor
    func testCopiedShowsWithTheCheckMarkAndBothRevertTogether() {
        let controller = makeController()
        load([
            ConversationMessage(seq: 1, role: "user", text: "one"),
            ConversationMessage(seq: 2, role: "assistant", text: "two"),
        ], into: controller)
        controller.copyFeedbackSeconds = 0.6
        let state = """
            JSON.stringify(Array.from(document.querySelectorAll('.cp')).map(b => b.dataset.state + ':' +
              b.querySelectorAll('.cpd').length + ':' +
              (b.querySelector('.cpd') ? getComputedStyle(b.querySelector('.cpd'), '::before').content : '')))
            """
        XCTAssertEqual(evaluate(state, in: controller) as? String, #"["idle:0:","idle:0:"]"#)
        _ = evaluate("document.querySelectorAll('.cp')[1].click(); 0", in: controller)
        XCTAssertEqual(waitForJS(state, toEqual: #"["idle:0:","done:1:\"Copied\""]"#, in: controller),
                       #"["idle:0:","done:1:\"Copied\""]"#)
        XCTAssertEqual(waitForJS(state, toEqual: #"["idle:0:","idle:0:"]"#, in: controller), #"["idle:0:","idle:0:"]"#)
    }

    @MainActor
    func testCopiedSitsLeftOfTheIconWithoutMovingAnything() {
        let controller = makeController()
        load([
            ConversationMessage(seq: 1, role: "user", text: "one"),
            ConversationMessage(seq: 2, role: "assistant", text: "two"),
        ], into: controller)
        controller.copyFeedbackSeconds = 30
        let geometry = """
            JSON.stringify(Array.from(document.querySelectorAll('[data-mi]')).map(m => {
              const who = m.querySelector('.who').getBoundingClientRect();
              const icon = m.querySelector('.cp svg').getBoundingClientRect();
              const content = m.querySelector('.mt, .body').getBoundingClientRect();
              return [who.height, who.top, icon.left, icon.top, content.top].join(',');
            }))
            """
        let before = evaluate(geometry, in: controller) as? String
        _ = evaluate("document.querySelectorAll('.cp')[0].click(); 0", in: controller)
        XCTAssertEqual(waitForJS("document.querySelectorAll('.cp')[0].dataset.state", toEqual: "done", in: controller), "done")
        XCTAssertEqual(evaluate(geometry, in: controller) as? String, before,
                       "the label row's height and every other position stay")
        let placement = evaluate(
            """
            JSON.stringify((function() {
              const tag = document.querySelector('.cpd');
              const t = tag.getBoundingClientRect();
              const icon = document.querySelector('.cp svg').getBoundingClientRect();
              const button = document.querySelector('.cp').getBoundingClientRect();
              const cs = getComputedStyle(tag);
              return {
                gap: Math.round(button.left - t.right),
                centered: Math.abs((t.top + t.bottom) / 2 - (icon.top + icon.bottom) / 2) <= 1,
                size: cs.fontSize, padding: cs.padding, radius: cs.borderRadius, border: cs.borderTopWidth
              };
            })())
            """,
            in: controller) as? String
        XCTAssertEqual(placement,
                       #"{"gap":4,"centered":true,"size":"11px","padding":"3px 6px","radius":"4px","border":"1px"}"#)
    }

    @MainActor
    func testCopiedFollowsTheTextSizeByRatio() {
        let controller = makeController()
        load([ConversationMessage(seq: 1, role: "user", text: "one")], into: controller)
        controller.copyFeedbackSeconds = 30
        controller.setTextSize(26)
        _ = evaluate("document.querySelector('.cp').click(); 0", in: controller)
        XCTAssertEqual(waitForJS("document.querySelector('.cp').dataset.state", toEqual: "done", in: controller), "done")
        let probe = evaluate(
            "JSON.stringify((function() { const cs = getComputedStyle(document.querySelector('.cpd')); return [cs.fontSize, cs.padding, cs.borderRadius]; })())",
            in: controller) as? String
        XCTAssertEqual(probe, #"["22px","3px 6px","4px"]"#, "the text scales; padding and radius stay")
    }

    @MainActor
    func testCopiedStaysOutOfTheSelectionAndTheCopy() {
        let controller = makeController()
        load([
            ConversationMessage(seq: 1, role: "user", text: "abc def"),
            ConversationMessage(seq: 2, role: "assistant", text: "ghi"),
        ], into: controller)
        controller.copyFeedbackSeconds = 30
        _ = evaluate("document.querySelectorAll('.cp')[0].click(); 0", in: controller)
        XCTAssertEqual(waitForJS("document.querySelectorAll('.cp')[0].dataset.state", toEqual: "done", in: controller), "done")
        let probe = evaluate(
            """
            (function() {
              getSelection().selectAllChildren(document.getElementById('doc'));
              return JSON.stringify({
                text: getSelection().toString().includes('Copied'),
                content: document.getElementById('doc').textContent.includes('Copied'),
                ranges: shiibarAPI.selectionRanges(),
                userSelect: getComputedStyle(document.querySelector('.cpd')).webkitUserSelect
              });
            })()
            """,
            in: controller) as? String
        XCTAssertEqual(probe, #"{"text":false,"content":false,"ranges":[{"m":0,"s":0,"l":7},{"m":1,"s":0,"l":3}],"userSelect":"none"}"#)
    }

    /// A second press restarts the duration. A 3-second duration keeps the
    /// waits well clear of scheduling noise: the second press comes 1.5 s
    /// in, and the feedback is still shown 1.5 s after it (3 s after the
    /// first press, when the first press's own timer would have ended).
    @MainActor
    func testPressingAgainRestartsTheDuration() {
        let controller = makeController()
        load([ConversationMessage(seq: 1, role: "user", text: "one")], into: controller)
        controller.copyFeedbackSeconds = 3.0
        let state = "document.querySelector('.cp').dataset.state + ':' + document.querySelectorAll('.cpd').length"
        _ = evaluate("document.querySelector('.cp').click(); 0", in: controller)
        XCTAssertEqual(waitForJS(state, toEqual: "done:1", in: controller), "done:1")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        _ = evaluate("document.querySelector('.cp').click(); 0", in: controller)
        RunLoop.main.run(until: Date().addingTimeInterval(1.8))
        XCTAssertEqual(evaluate(state, in: controller) as? String, "done:1")
        XCTAssertEqual(waitForJS(state, toEqual: "idle:0", in: controller), "idle:0")
    }

    @MainActor
    func testCopiedSurvivesAFoldToggleOfItsMessage() {
        let long = String(repeating: "filler words ", count: 60)
        let controller = makeController()
        load([ConversationMessage(seq: 4, role: "assistant", text: long)], into: controller)
        controller.copyFeedbackSeconds = 30
        _ = evaluate("document.querySelector('.cp').click(); 0", in: controller)
        let state = "document.querySelector('.cp').dataset.state + ':' + document.querySelectorAll('.cpd').length"
        XCTAssertEqual(waitForJS(state, toEqual: "done:1", in: controller), "done:1")
        _ = evaluate("document.querySelector('.expand').click(); 0", in: controller)
        XCTAssertEqual(evaluate("document.querySelector('.expand').textContent", in: controller) as? String, "Show less")
        XCTAssertEqual(evaluate(state, in: controller) as? String, "done:1")
        _ = evaluate("document.querySelector('.expand').click(); 0", in: controller)
        XCTAssertEqual(evaluate(state, in: controller) as? String, "done:1")
    }
}
