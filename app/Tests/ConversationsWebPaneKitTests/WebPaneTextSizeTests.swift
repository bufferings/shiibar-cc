import AppKit
import ShiibarCcCore
import WebKit
import XCTest
@testable import ConversationsWebPaneKit

/// The message surface follows the text size (DESIGN.md §4.6 "text size of
/// the conversation pane", §4.5 "text size"): the body is the setting in
/// px; every other font size, the copy icon and the vertical margins and
/// paddings are their values at 13 times the ratio; horizontal paddings,
/// the minimap width and the radii stay. The ratio survives the held-state
/// flush and the process-termination replay.
final class WebPaneTextSizeTests: XCTestCase {
    private static let source = """
        # Heading

        A paragraph with `code` in it.

        ```
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |
        """

    private let messages = [
        ConversationMessage(seq: 1, role: "user", text: "a request"),
        ConversationMessage(seq: 2, role: "assistant", text: source),
    ]

    @MainActor
    private func makeController(sized: Bool = true) -> WebPaneController {
        let controller = WebPaneController()
        controller.openExternalURL = { XCTFail("no test may open a URL: \($0)") }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("cc.shiibar.tests." + UUID().uuidString))
        if sized { controller.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 800) }
        return controller
    }

    @MainActor
    private func loadAndWait(_ controller: WebPaneController) {
        waitForRender(of: controller) {
            controller.load(messages: messages, rendered: messages.map { RenderedMessage(role: $0.role, text: $0.text) }, anchorSeq: nil)
        }
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

    /// Computed metrics in px, keyed by name.
    private static let probe = """
        JSON.stringify((function() {
          const px = v => parseFloat(v);
          const cs = s => getComputedStyle(document.querySelector(s));
          const band = cs('.msg.band');
          const pre = cs('pre');
          const td = cs('.tbl td');
          const doc = cs('#doc');
          return {
            body: px(cs('.msg.ans').fontSize),
            label: px(cs('.who').fontSize),
            labelGap: px(cs('.who').marginBottom),
            mine: px(cs('.mt').fontSize),
            h1: px(cs('.body h1').fontSize),
            h1Top: px(cs('.body h1').marginTop),
            p: px(cs('.body p').marginBottom),
            pre: px(pre.fontSize),
            preTop: px(pre.paddingTop),
            preLeft: px(pre.paddingLeft),
            table: px(cs('.tbl table').fontSize),
            cellTop: px(td.paddingTop),
            cellLeft: px(td.paddingLeft),
            bandTop: px(band.paddingTop),
            bandBottom: px(band.paddingBottom),
            bandLeft: px(band.paddingLeft),
            bandRight: px(band.paddingRight),
            docTop: px(doc.paddingTop),
            replyGap: px(cs('.msg.ans').marginTop),
            icon: document.querySelector('.cp svg').getBoundingClientRect().width,
            endcap: px(cs('.endcap').fontSize),
            endcapTop: px(cs('.endcap').marginTop),
            endcapSide: px(cs('.endcap').marginLeft),
            minimap: document.getElementById('mm').getBoundingClientRect().width,
            radius: px(pre.borderTopLeftRadius),
            k: getComputedStyle(document.documentElement).getPropertyValue('--k').trim()
          };
        })())
        """

    @MainActor
    private func metrics(_ controller: WebPaneController) -> [String: Any] {
        let json = evaluate(Self.probe, in: controller) as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private func number(_ metrics: [String: Any], _ key: String) -> Double {
        (metrics[key] as? NSNumber)?.doubleValue ?? .nan
    }

    @MainActor
    func testScaledAndFixedValuesAtEighteen() {
        let controller = makeController()
        loadAndWait(controller)
        let base = metrics(controller)
        controller.setTextSize(18)
        let large = metrics(controller)
        let k = 18.0 / 13.0

        // At 13 the values are window-design.html's.
        let expectedAtBase: [String: Double] = [
            "body": 13, "label": 11, "labelGap": 2, "mine": 13.5, "h1": 19, "h1Top": 10, "p": 8,
            "pre": 11.5, "preTop": 9, "preLeft": 12, "table": 13, "cellTop": 5, "cellLeft": 12,
            "bandTop": 7, "bandBottom": 8, "bandLeft": 16, "bandRight": 18, "docTop": 12, "replyGap": 10,
            "icon": 14, "endcap": 11, "endcapTop": 14, "endcapSide": 16, "minimap": 20, "radius": 8,
        ]
        for (key, value) in expectedAtBase {
            XCTAssertEqual(number(base, key), value, accuracy: 0.01, "\(key) at 13")
        }

        let scaled = ["body", "label", "labelGap", "mine", "h1", "h1Top", "p", "pre", "preTop", "table",
                      "cellTop", "bandTop", "bandBottom", "docTop", "replyGap", "icon", "endcap", "endcapTop"]
        for key in scaled {
            XCTAssertEqual(number(large, key), expectedAtBase[key, default: .nan] * k, accuracy: 0.02, "\(key) at 18 follows the ratio")
        }
        let fixed = ["preLeft", "cellLeft", "bandLeft", "bandRight", "endcapSide", "minimap", "radius"]
        for key in fixed {
            XCTAssertEqual(number(large, key), expectedAtBase[key, default: .nan], accuracy: 0.01, "\(key) at 18 stays")
        }
        XCTAssertEqual(Double(large["k"] as? String ?? "") ?? .nan, k, accuracy: 1e-9)
    }

    @MainActor
    func testHeldSizeFlushesWithItsRatio() {
        let controller = makeController(sized: false)
        controller.load(messages: messages, rendered: messages.map { RenderedMessage(role: $0.role, text: $0.text) }, anchorSeq: nil)
        controller.setTextSize(9)
        let rendered = renderExpectation(description: "rendered after sizing")
        controller.onRendered = { _ in rendered.fulfill() }
        controller.webView.setFrameSize(NSSize(width: 720, height: 600))
        wait(for: [rendered], timeout: 20)
        let held = metrics(controller)
        XCTAssertEqual(number(held, "body"), 9, accuracy: 0.01)
        XCTAssertEqual(number(held, "label"), 11 * 9 / 13, accuracy: 0.02)
        XCTAssertEqual(Double(held["k"] as? String ?? "") ?? .nan, 9.0 / 13.0, accuracy: 1e-9)
    }

    @MainActor
    func testProcessTerminationReplayKeepsTheRatio() {
        let controller = makeController()
        loadAndWait(controller)
        controller.setTextSize(18)
        let reRender = renderExpectation(description: "re-render after recovery")
        controller.onRendered = { _ in reRender.fulfill() }
        controller.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(controller.webView)
        wait(for: [reRender], timeout: 20)
        let replayed = metrics(controller)
        XCTAssertEqual(number(replayed, "body"), 18, accuracy: 0.01)
        XCTAssertEqual(number(replayed, "pre"), 11.5 * 18 / 13, accuracy: 0.02)
        XCTAssertEqual(Double(replayed["k"] as? String ?? "") ?? .nan, 18.0 / 13.0, accuracy: 1e-9)
        XCTAssertEqual(controller.textSizePoints, 18)
    }
}
