import XCTest
@testable import ShiibarCcCore

/// The Conversations window's key-command mapping (DESIGN.md §4.6/§8.38(7)):
/// what the window-scoped monitor consumes (text size, ⌘G find navigation)
/// and — just as load-bearing — what it must pass through (⌘C belongs to
/// the message pane).
final class ConversationsKeyCommandsTests: XCTestCase {
    private func command(
        _ key: String?, command: Bool = true, shift: Bool = false, other: Bool = false
    ) -> ConversationsKeyCommand? {
        ConversationsKeyCommands.command(
            charactersIgnoringModifiers: key,
            hasCommand: command, hasShift: shift, hasOtherModifiers: other
        )
    }

    func testTextSizeCommands() {
        XCTAssertEqual(command("+"), .increaseTextSize)
        XCTAssertEqual(command("+", shift: true), .increaseTextSize) // plus IS shift-equals
        XCTAssertEqual(command("="), .increaseTextSize)
        XCTAssertEqual(command("-"), .decreaseTextSize)
        XCTAssertEqual(command("0"), .resetTextSize)
    }

    func testFindNavigationCommands() {
        // §8.38(7): next match = cmd-G (toward newer), previous = shift-cmd-G
        // (toward older). Shift produces the uppercase form in
        // charactersIgnoringModifiers.
        XCTAssertEqual(command("g"), .nextMatch)
        XCTAssertEqual(command("G", shift: true), .previousMatch)
        // Incoherent combinations pass through.
        XCTAssertNil(command("g", shift: true))
        XCTAssertNil(command("G", shift: false))
    }

    func testFocusSearchCommand() {
        // §4.6/§8.41: ⌘F focuses the search field; ⇧⌘F stays unclaimed.
        XCTAssertEqual(command("f"), .focusSearch)
        XCTAssertNil(command("F", shift: true))
        XCTAssertNil(command("f", command: false))
    }

    func testPassThroughs() {
        // ⌘C / ⇧⌘C belong to the message pane — never consumed here.
        XCTAssertNil(command("c"))
        XCTAssertNil(command("C", shift: true))
        // No command modifier: plain typing passes through.
        XCTAssertNil(command("g", command: false))
        XCTAssertNil(command("+", command: false))
        // Option/control chords are someone else's shortcuts.
        XCTAssertNil(command("g", other: true))
        XCTAssertNil(command("+", other: true))
        XCTAssertNil(command(nil))
        XCTAssertNil(command("w"))
        XCTAssertNil(command("q"))
    }
}

/// Find-bar navigation targets (§4.6/§8.38(7)(8)): wrapping at the ends
/// (the ⌘G convention) and always producing a target while hits exist —
/// the regression pin for the round-4 "single hit / folded hit doesn't
/// navigate" defect, whose cause was navigation guards that skipped the
/// jump when the index had nowhere to move.
final class ConversationsHitNavigationTests: XCTestCase {
    func testSingleHitWrapsOntoItselfAndStillJumps() {
        // One hit: the wrap lands on the same index, and a target IS
        // produced — the press must still re-scroll to the hit (§4.6).
        XCTAssertEqual(ConversationsHitNavigation.next(current: 0, count: 1), 0)
        XCTAssertEqual(ConversationsHitNavigation.previous(current: 0, count: 1), 0)
    }

    func testWrapsAtTheEnds() {
        // §8.38(8): the ⌘G convention wraps.
        XCTAssertEqual(ConversationsHitNavigation.next(current: 4, count: 5), 0)
        XCTAssertEqual(ConversationsHitNavigation.previous(current: 0, count: 5), 4)
        XCTAssertEqual(ConversationsHitNavigation.next(current: 2, count: 5), 3)
        XCTAssertEqual(ConversationsHitNavigation.previous(current: 2, count: 5), 1)
    }

    func testNoCurrentFallsBackToTheLatestHit() {
        XCTAssertEqual(ConversationsHitNavigation.next(current: nil, count: 3), 2)
        XCTAssertEqual(ConversationsHitNavigation.previous(current: nil, count: 3), 2)
    }

    func testNoHitsYieldsNothing() {
        XCTAssertNil(ConversationsHitNavigation.next(current: nil, count: 0))
        XCTAssertNil(ConversationsHitNavigation.previous(current: 0, count: 0))
    }

    func testOutOfRangeCurrentIsClampedBeforeWrapping() {
        XCTAssertEqual(ConversationsHitNavigation.next(current: 99, count: 3), 0)
        XCTAssertEqual(ConversationsHitNavigation.previous(current: -5, count: 3), 2)
    }
}
