import AppKit
import ShiibarCcCore
import SwiftUI
import XCTest
@testable import ShiibarCcApp

/// The IME-aware search field (§4.6/§8.38(12)): it never propagates
/// half-composed text and always propagates the commit. (NFC dispatch and
/// focus requests are covered by `MainSurfaceModelTests`.)
@MainActor
final class ConversationsSearchInputTests: XCTestCase {
    // "left-navi": NFD types hi (U+30D2) + combining dakuten (U+3099).
    // Escapes keep the source ASCII.
    private let navNFD = "\u{30EC}\u{30D5}\u{30C8}\u{30CA}\u{30D2}\u{3099}"


    func testFieldNeverPropagatesWhileComposingAndAlwaysOnCommit() {
        var bound = ""
        let binding = Binding(get: { bound }, set: { bound = $0 })
        let coordinator = ConversationsSearchField.Coordinator(text: binding)

        // The IME composing sequence: marked text active on every change.
        coordinator.handleTextChange("\u{308C}", isComposing: true)
        coordinator.handleTextChange("\u{308C}\u{3075}", isComposing: true)
        coordinator.handleTextChange(navNFD, isComposing: true)
        XCTAssertEqual(bound, "", "no dispatch while marked text is active (\u{00A7}4.6)")

        // The commit: marked text resolved, same string, must propagate.
        coordinator.handleTextChange(navNFD, isComposing: false)
        XCTAssertEqual(bound, navNFD, "the commit must always propagate")

        // Plain (non-IME) typing propagates immediately.
        coordinator.handleTextChange("plain", isComposing: false)
        XCTAssertEqual(bound, "plain")
    }

    /// §4.6: the clear button empties the field through the same handler as
    /// a keyboard edit and puts focus in the field. Built without a window:
    /// focus is checked with a spy in place of `makeFirstResponder`.
    func testClearButtonEmptiesTheFieldAndRequestsFocus() {
        var bound = ""
        let binding = Binding(get: { bound }, set: { bound = $0 })
        let field = ConversationsSearchField(text: binding, isEnabled: true, focusToken: 0)
        let coordinator = field.makeCoordinator()
        let view = SearchFieldView()
        view.textField.delegate = coordinator
        coordinator.view = view
        view.onTextCleared = { coordinator.handleTextChange("", isComposing: false) }
        var focusRequests = 0
        view.focusTextField = { requested in
            XCTAssertTrue(requested === view)
            focusRequests += 1
        }

        view.textField.stringValue = "tag"
        coordinator.handleTextChange("tag", isComposing: false)
        view.updateClearButton()
        XCTAssertEqual(bound, "tag")
        XCTAssertFalse(view.clearButton.isHidden, "shown while the field holds text")

        // A click dispatches through the application object and needs a
        // window; check the button's wiring, then run its action directly.
        let button = view.clearButton
        XCTAssertTrue(button.target === view)
        XCTAssertEqual(button.action, #selector(SearchFieldView.clearButtonPressed))
        view.clearButtonPressed()

        XCTAssertEqual(view.textField.stringValue, "")
        XCTAssertEqual(bound, "", "the empty text reaches the binding")
        XCTAssertEqual(focusRequests, 1)
        XCTAssertTrue(view.clearButton.isHidden, "hidden once the field is empty")
    }

    func testClearButtonFollowsTheEnabledState() {
        let view = SearchFieldView()
        XCTAssertTrue(view.clearButton.isHidden, "hidden while the field is empty")
        view.textField.stringValue = "tag"
        view.textField.isEnabled = false
        view.updateClearButton()
        XCTAssertTrue(view.clearButton.isHidden, "hidden while the field is disabled")
        view.textField.isEnabled = true
        view.updateClearButton()
        XCTAssertFalse(view.clearButton.isHidden)
    }

    func testClearButtonNeverTakesKeyboardFocus() {
        let button = SearchFieldView().clearButton
        XCTAssertTrue(button.refusesFirstResponder)
        XCTAssertFalse(button.acceptsFirstResponder)
        XCTAssertFalse(button.canBecomeKeyView)
        XCTAssertEqual(button.toolTip, "Clear")
        XCTAssertEqual(button.accessibilityLabel(), "Clear search")
    }
}
