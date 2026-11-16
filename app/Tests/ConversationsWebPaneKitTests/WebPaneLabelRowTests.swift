import AppKit
import ShiibarCcCore
import WebKit
import XCTest
@testable import ConversationsWebPaneKit

/// The label row and the per-message copy button (DESIGN.md §4.6 "rendering
/// grammar" / "per-message copy", §8.49, §9; window-design.html "message
/// surface grammar"): every message gets a `You` / `Claude` label that is
/// chrome — outside hits, fold boundaries, selection ranges, and copies —
/// and a copy button whose press makes Swift write the message's full text
/// to the injected pasteboard, followed by a check-mark feedback.
final class WebPaneLabelRowTests: XCTestCase {
    // MARK: - Harness (same sandbox discipline as the other kit tests:
    // named pasteboards, external opens fail the test)

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

    @MainActor
    private func waitForPasteboardString(_ pasteboard: NSPasteboard) -> String? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let string = pasteboard.string(forType: .string) { return string }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    /// Poll a JS expression until it returns `expected` (or time out).
    @MainActor
    private func waitForJS(_ script: String, toEqual expected: String, in controller: WebPaneController) -> String? {
        let deadline = Date().addingTimeInterval(10)
        var last: String?
        while Date() < deadline {
            last = evaluate(script, in: controller) as? String
            if last == expected { return last }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return last
    }

    /// Click message `index`'s copy button the way the page wires it.
    @MainActor
    private func clickCopyButton(_ index: Int, in controller: WebPaneController) {
        _ = evaluate("document.querySelectorAll('.cp')[\(index)].click(); 0", in: controller)
    }

    // MARK: - Label row: present, one per message, chrome only

    @MainActor
    func testEveryMessageGetsALabelRowIncludingConsecutiveClaudeMessages() {
        let controller = loadedController([
            ConversationMessage(seq: 1, role: "user", text: "please refactor"),
            ConversationMessage(seq: 2, role: "assistant", text: "first reply"),
            ConversationMessage(seq: 3, role: "assistant", text: "second reply"),
        ])
        let probe = evaluate(
            """
            JSON.stringify(Array.from(document.querySelectorAll('[data-mi]')).map(m => {
              const who = m.firstElementChild;
              return {
                cls: m.className,
                who: who.className,
                label: getComputedStyle(who, '::before').content,
                buttons: m.querySelectorAll('.who > .cp').length,
                tooltip: m.querySelector('.cp').title
              };
            }))
            """,
            in: controller
        ) as? String ?? ""
        XCTAssertEqual(
            probe,
            #"[{"cls":"msg band","who":"who you","label":"\"You\"","buttons":1,"tooltip":"Copy"},"#
                + #"{"cls":"msg ans","who":"who ai","label":"\"Claude\"","buttons":1,"tooltip":"Copy"},"#
                + #"{"cls":"msg ans","who":"who ai","label":"\"Claude\"","buttons":1,"tooltip":"Copy"}]"#
        )
        // Labels are generated content: never part of the document's text.
        let text = evaluate("document.getElementById('doc').textContent", in: controller) as? String ?? ""
        XCTAssertFalse(text.contains("You"), text)
        XCTAssertFalse(text.contains("Claude"), text)
        // The old leading markers are gone.
        XCTAssertFalse(text.contains("\u{276F}"), text)
        XCTAssertFalse(text.contains("\u{23FA}"), text)
    }

    @MainActor
    func testLabelsStayOutOfSelectionRangesAndSelectedText() {
        let messages = [
            ConversationMessage(seq: 1, role: "user", text: "abc def"),
            ConversationMessage(seq: 2, role: "assistant", text: "ghi **jkl**"),
        ]
        let controller = loadedController(messages)
        let probe = evaluate(
            """
            (function() {
              getSelection().selectAllChildren(document.getElementById('doc'));
              return JSON.stringify({
                ranges: shiibarAPI.selectionRanges(),
                text: getSelection().toString()
              });
            })()
            """,
            in: controller
        ) as? String ?? ""
        // Exactly the rendered content lengths: "abc def" (7) and "ghi jkl"
        // (7) — no label offsets added in front.
        XCTAssertTrue(probe.contains(#""ranges":[{"m":0,"s":0,"l":7},{"m":1,"s":0,"l":7}]"#), probe)
        XCTAssertFalse(probe.contains("You"), probe)
        XCTAssertFalse(probe.contains("Claude"), probe)
    }

    @MainActor
    func testSearchingForTheLabelWordHitsOnlyTheContent() {
        let messages = [
            ConversationMessage(seq: 1, role: "user", text: "ask You about it"),
            ConversationMessage(seq: 2, role: "assistant", text: "Claude answers"),
        ]
        let controller = loadedController(messages)
        let rendered = messages.map { RenderedMessage(role: $0.role, text: $0.text) }
        let hits = ConversationHits.locations(messageTexts: rendered.map(\.renderedText), terms: ["you", "claude"])
        XCTAssertEqual(hits.count, 2, "Core counts the content occurrences only")
        let applied = expectation(description: "hits applied")
        controller.onHitsApplied = { _ in applied.fulfill() }
        controller.setHits(hits, rendered: rendered, current: 1)
        wait(for: [applied], timeout: 10)

        // Every painted range sits inside the content, never in a label row.
        let probe = evaluate(
            """
            JSON.stringify((function() {
              const all = [];
              ['shiibar-hit', 'shiibar-hit-current'].forEach(name => {
                const h = CSS.highlights.get(name);
                if (h) h.forEach(r => all.push(r));
              });
              return {
                count: all.length,
                inLabel: all.filter(r => r.startContainer.parentElement.closest('.who')).length,
                texts: all.map(r => r.toString()).sort()
              };
            })())
            """,
            in: controller
        ) as? String ?? ""
        XCTAssertEqual(probe, #"{"count":2,"inLabel":0,"texts":["Claude","You"]}"#)
    }

    @MainActor
    func testFoldBoundaryIgnoresTheLabel() {
        // Exactly the §9 limit: does not fold. One more character: folds,
        // and the visible part is exactly the limit — the label adds nothing.
        let limit = ConversationsConstants.messageFoldCharacterLimit
        let atLimit = String(repeating: "a", count: limit)
        let overLimit = String(repeating: "b", count: limit + 1)
        let controller = loadedController([
            ConversationMessage(seq: 1, role: "user", text: atLimit),
            ConversationMessage(seq: 2, role: "user", text: overLimit),
        ])
        let probe = evaluate(
            """
            JSON.stringify(Array.from(document.querySelectorAll('.mt')).map(mt => ({
              len: mt.textContent.length,
              expand: !!mt.parentElement.querySelector('.expand')
            })))
            """,
            in: controller
        ) as? String ?? ""
        XCTAssertEqual(probe, #"[{"len":\#(limit),"expand":false},{"len":\#(limit),"expand":true}]"#)
    }

    // MARK: - Layout values (window-design.html CSS, §8.39 / §9)

    @MainActor
    func testLabelRowAndBandMetricsMatchTheDesignCSS() {
        let controller = loadedController([
            ConversationMessage(seq: 1, role: "user", text: "a request"),
            ConversationMessage(seq: 2, role: "assistant", text: "a reply paragraph"),
        ])
        let probe = evaluate(
            """
            JSON.stringify((function() {
              const band = document.querySelector('.msg.band');
              const ans = document.querySelector('.msg.ans');
              const who = getComputedStyle(document.querySelector('.who'));
              const mt = getComputedStyle(document.querySelector('.mt'));
              const cp = document.querySelector('.cp');
              const b = getComputedStyle(band);
              return {
                whoSize: who.fontSize, whoWeight: who.fontWeight, whoLine: who.lineHeight,
                whoGap: who.marginBottom,
                band: [b.paddingTop, b.paddingRight, b.paddingBottom, b.paddingLeft].join(' '),
                bandToReply: getComputedStyle(ans).marginTop,
                mtSize: mt.fontSize, mtLine: mt.lineHeight, mtWeight: mt.fontWeight,
                ansLine: getComputedStyle(ans).lineHeight,
                icon: cp.querySelector('svg').getBoundingClientRect().width,
                cpRight: getComputedStyle(cp).marginRight
              };
            })())
            """,
            in: controller
        ) as? String ?? ""
        XCTAssertEqual(
            probe,
            #"{"whoSize":"11px","whoWeight":"650","whoLine":"17.6px","whoGap":"2px","band":"7px 18px 8px 16px","#
                + #""bandToReply":"10px","mtSize":"13.5px","mtLine":"21.6px","mtWeight":"400","ansLine":"22.1px","#
                + #""icon":14,"cpRight":"10px"}"#
        )
    }

    @MainActor
    func testTextAndCopyButtonsStayEightPointsShortOfTheMinimap() {
        let controller = loadedController([
            ConversationMessage(seq: 1, role: "user", text: String(repeating: "long words ", count: 40)),
            ConversationMessage(seq: 2, role: "assistant", text: String(repeating: "reply words ", count: 40)),
        ])
        let probe = evaluate(
            """
            JSON.stringify((function() {
              const mmLeft = document.getElementById('mm').getBoundingClientRect().left;
              const contentRight = el => el.getBoundingClientRect().right - parseFloat(getComputedStyle(el).paddingRight);
              const band = document.querySelector('.msg.band');
              return {
                mt: mmLeft - contentRight(document.querySelector('.mt')),
                p: mmLeft - contentRight(document.querySelector('.body p')),
                cps: Array.from(document.querySelectorAll('.cp')).map(c => mmLeft - c.getBoundingClientRect().right),
                bandReachesEdge: band.getBoundingClientRect().right === window.innerWidth
              };
            })())
            """,
            in: controller
        ) as? String ?? ""
        // §9: text wraps 8pt before the minimap (the user text adds 4pt
        // more per the design's 14px); the band background still reaches
        // the right edge.
        XCTAssertEqual(probe, #"{"mt":12,"p":8,"cps":[8,8],"bandReachesEdge":true}"#)
    }

    // MARK: - Per-message copy: page reports the seq, Swift writes the text

    @MainActor
    func testCopyButtonCopiesTheUserTextAsTyped() {
        let messages = [
            ConversationMessage(seq: 7, role: "user", text: "keep *stars* and `ticks` literal"),
            ConversationMessage(seq: 8, role: "assistant", text: "ok"),
        ]
        let controller = loadedController(messages)
        var notified: [Int64] = []
        controller.onMessageCopied = { notified.append($0) }
        clickCopyButton(0, in: controller)
        XCTAssertEqual(waitForPasteboardString(controller.pasteboard), "keep *stars* and `ticks` literal")
        XCTAssertEqual(notified, [7])
    }

    @MainActor
    func testCopyButtonCopiesTheClaudeMarkdownSource() {
        let source = "# Plan\n\n- **first** step\n- second\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```"
        let messages = [
            ConversationMessage(seq: 1, role: "user", text: "plan?"),
            ConversationMessage(seq: 2, role: "assistant", text: source),
        ]
        let controller = loadedController(messages)
        clickCopyButton(1, in: controller)
        XCTAssertEqual(waitForPasteboardString(controller.pasteboard), source)
    }

    @MainActor
    func testCopyButtonCopiesTheFullTextOfAFoldedMessage() {
        let source = "**Intro** " + String(repeating: "filler words ", count: 60) + "the hidden tail"
        let controller = loadedController([
            ConversationMessage(seq: 5, role: "assistant", text: source),
        ])
        let foldedNow = evaluate(
            "document.querySelector('.expand').textContent.startsWith('Show full message')",
            in: controller
        ) as? Bool
        XCTAssertEqual(foldedNow, true, "fixture must be folded")
        clickCopyButton(0, in: controller)
        XCTAssertEqual(waitForPasteboardString(controller.pasteboard), source)
    }

    @MainActor
    func testCopyButtonLeavesTheSelectionAlone() {
        let controller = loadedController([
            ConversationMessage(seq: 1, role: "user", text: "first message words"),
            ConversationMessage(seq: 2, role: "assistant", text: "second message words"),
        ])
        let before = evaluate(
            """
            (function() {
              const mt = document.querySelector('.mt').firstChild;
              getSelection().setBaseAndExtent(mt, 0, mt, 5);
              return JSON.stringify(shiibarAPI.selectionRanges());
            })()
            """,
            in: controller
        ) as? String
        XCTAssertEqual(before, #"[{"m":0,"s":0,"l":5}]"#)
        // A real press: mousedown + click on the second message's button.
        _ = evaluate(
            """
            (function() {
              const b = document.querySelectorAll('.cp')[1];
              b.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true}));
              b.click();
              return 0;
            })()
            """,
            in: controller
        )
        XCTAssertEqual(waitForPasteboardString(controller.pasteboard), "second message words")
        let after = evaluate("JSON.stringify(shiibarAPI.selectionRanges())", in: controller) as? String
        XCTAssertEqual(after, before, "the copy button must not change the selection")
    }

    @MainActor
    func testCopyShowsACheckMarkThatRevertsAfterTheFeedbackDuration() {
        let controller = loadedController([
            ConversationMessage(seq: 1, role: "user", text: "one"),
            ConversationMessage(seq: 2, role: "assistant", text: "two"),
        ])
        controller.copyFeedbackSeconds = 0.6
        let state = "JSON.stringify(Array.from(document.querySelectorAll('.cp')).map(b => b.dataset.state + ':' + b.querySelectorAll('path').length))"
        XCTAssertEqual(evaluate(state, in: controller) as? String, #"["idle:2","idle:2"]"#)

        clickCopyButton(1, in: controller)
        // Only the pressed message shows the check mark (one path).
        XCTAssertEqual(waitForJS(state, toEqual: #"["idle:2","done:1"]"#, in: controller), #"["idle:2","done:1"]"#)
        // Same position and size as the copy icon (window-design.html).
        let size = evaluate(
            "document.querySelectorAll('.cp svg')[1].getBoundingClientRect().width",
            in: controller
        ) as? Int
        XCTAssertEqual(size, 14)
        // ...and reverts after the duration.
        XCTAssertEqual(waitForJS(state, toEqual: #"["idle:2","idle:2"]"#, in: controller), #"["idle:2","idle:2"]"#)
    }

    @MainActor
    func testCheckMarkSurvivesAFoldToggleOfItsMessage() {
        let long = String(repeating: "filler words ", count: 60)
        let controller = loadedController([
            ConversationMessage(seq: 4, role: "assistant", text: long),
        ])
        controller.copyFeedbackSeconds = 30
        clickCopyButton(0, in: controller)
        let state = "document.querySelector('.cp').dataset.state"
        XCTAssertEqual(waitForJS(state, toEqual: "done", in: controller), "done")
        _ = evaluate("document.querySelector('.expand').click(); 0", in: controller)
        XCTAssertEqual(evaluate("document.querySelector('.expand').textContent", in: controller) as? String, "Show less")
        XCTAssertEqual(evaluate(state, in: controller) as? String, "done")
    }

    @MainActor
    func testUnknownSeqWritesNothingAndShowsNoCheckMark() {
        let controller = loadedController([
            ConversationMessage(seq: 1, role: "assistant", text: "text"),
        ])
        controller.copyMessage(seq: 999)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(controller.pasteboard.string(forType: .string))
        XCTAssertEqual(evaluate("document.querySelector('.cp').dataset.state", in: controller) as? String, "idle")
    }
}
