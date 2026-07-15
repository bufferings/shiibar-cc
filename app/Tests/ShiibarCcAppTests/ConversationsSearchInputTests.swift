import AppKit
import ShiibarCcCore
import SwiftUI
import XCTest
@testable import ShiibarCcApp

/// Round-8 search-input fixes (§4.6/§8.38(12)): the query normalizes to NFC
/// before dispatch (defense in depth beside the CLI's own normalization),
/// the IME-aware field never propagates half-composed text and always
/// propagates the commit, and ⌘F requests land as focus tokens.
@MainActor
final class ConversationsSearchInputTests: XCTestCase {
    // "left-navi": NFD types hi (U+30D2) + combining dakuten (U+3099); the
    // composed form ends in bi (U+30D3). Escapes keep the source ASCII.
    private let navNFD = "\u{30EC}\u{30D5}\u{30C8}\u{30CA}\u{30D2}\u{3099}"
    private let navNFC = "\u{30EC}\u{30D5}\u{30C8}\u{30CA}\u{30D3}"

    func testDecomposedQueryDispatchesComposed() {
        let viewModel = ConversationsViewModel(appState: nil)
        var dispatched: [[String]] = []
        viewModel.searchProcessLauncher = { arguments, _, _ in
            dispatched.append(arguments)
            return ConversationsProcess(process: Process())
        }
        viewModel.query = navNFD // what the IME actually emits
        viewModel.queryChanged()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, dispatched.isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(dispatched.first, ["conversations", "search", navNFC, "--json"],
                       "the dispatched query must be the composed (NFC) form")
    }

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

    func testFocusSearchFieldBumpsTheToken() {
        let viewModel = ConversationsViewModel(appState: nil)
        let before = viewModel.searchFocusToken
        viewModel.focusSearchField()
        viewModel.focusSearchField()
        XCTAssertEqual(viewModel.searchFocusToken, before + 2)
    }
}
