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
}
