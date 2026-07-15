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

    func testSidebarWidthMatchesSpec() {
        // §9: sidebar initial 250pt, draggable 200-400pt (§8.38(7)).
        XCTAssertEqual(ConversationsConstants.sidebarInitialWidth, 250)
        XCTAssertEqual(ConversationsConstants.sidebarMinimumWidth, 200)
        XCTAssertEqual(ConversationsConstants.sidebarMaximumWidth, 400)
        XCTAssertEqual(ConversationsConstants.clampSidebarWidth(150), 200)
        XCTAssertEqual(ConversationsConstants.clampSidebarWidth(250), 250)
        XCTAssertEqual(ConversationsConstants.clampSidebarWidth(999), 400)
    }

    func testIndexWarmingCadenceMatchesSpec() {
        // §9: index warming ~10 minutes, tolerance 5 minutes.
        XCTAssertEqual(ConversationsIndexWarming.intervalSeconds, 600)
        XCTAssertEqual(ConversationsIndexWarming.toleranceSeconds, 300)
    }
}
