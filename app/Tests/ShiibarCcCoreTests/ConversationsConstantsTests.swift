import XCTest
@testable import ShiibarCcCore

/// Pins the Conversations tunables to DESIGN.md §9 (same role as
/// `PeriodicReconcileTests`).
final class ConversationsConstantsTests: XCTestCase {
    func testSearchDebounceMatchesSpec() {
        // §9: UI search debounce = 200ms.
        XCTAssertEqual(ConversationsConstants.searchDebounceSeconds, 0.2)
    }

    func testMessageFoldLimitMatchesSpec() {
        // §9: fold a message longer than 500 characters.
        XCTAssertEqual(ConversationsConstants.messageFoldCharacterLimit, 500)
    }

    func testIndexWarmingCadenceMatchesSpec() {
        // §9: index warming ~10 minutes, tolerance 5 minutes.
        XCTAssertEqual(ConversationsIndexWarming.intervalSeconds, 600)
        XCTAssertEqual(ConversationsIndexWarming.toleranceSeconds, 300)
    }
}
