import XCTest
@testable import ShiibarCcCore

final class ConversationsSearchTests: XCTestCase {
    // MARK: - Query term rules (§4.6)

    func testValidTermsKeepsTwoPlusCharacterWords() {
        XCTAssertEqual(ConversationsQuery.validTerms("worktree"), ["worktree"])
        XCTAssertEqual(ConversationsQuery.validTerms("keep on top"), ["keep", "on", "top"])
    }

    func testValidTermsDropsSingleCharacterWords() {
        // §4.6: 1-character words are ignored.
        XCTAssertEqual(ConversationsQuery.validTerms("a worktree"), ["worktree"])
        XCTAssertEqual(ConversationsQuery.validTerms("x y z"), [])
    }

    func testValidTermsTrimsAsciiAndFullWidthWhitespace() {
        // §4.6: surrounding whitespace, ASCII and full-width (U+3000, written
        // as an escape to keep the source ASCII), is trimmed and is also a
        // word separator.
        XCTAssertEqual(ConversationsQuery.validTerms("  hello  "), ["hello"])
        XCTAssertEqual(ConversationsQuery.validTerms("\u{3000}hello\u{3000}world\u{3000}"), ["hello", "world"])
    }

    func testTwoCharacterMultibyteWordIsValid() {
        // The 2+ character rule (§4.6) counts CHARACTERS, not bytes/scalars,
        // so a two-character multibyte word qualifies and a one-character one
        // does not. Code points written as escapes to keep the source ASCII:
        // U+4F1A U+8A71 (two characters), U+3042 (one character).
        XCTAssertEqual(ConversationsQuery.validTerms("\u{4f1a}\u{8a71}"), ["\u{4f1a}\u{8a71}"])
        XCTAssertEqual(ConversationsQuery.validTerms("\u{3042}"), [])
    }

    func testShouldIssueSearchMatchesValidTerms() {
        XCTAssertFalse(ConversationsQuery.shouldIssueSearch(""))
        XCTAssertFalse(ConversationsQuery.shouldIssueSearch("   "))
        XCTAssertFalse(ConversationsQuery.shouldIssueSearch("a"))
        XCTAssertTrue(ConversationsQuery.shouldIssueSearch("ab"))
        XCTAssertTrue(ConversationsQuery.shouldIssueSearch("a worktree"))
    }

    // MARK: - Hit locations (§4.6)

    func testHitLocationsInDocumentOrder() {
        let messages = ["worktree here", "no match", "another worktree and worktree"]
        let hits = ConversationHits.locations(messageTexts: messages, terms: ["worktree"])
        XCTAssertEqual(hits, [
            ConversationHit(messageIndex: 0, start: 0, length: 8),
            ConversationHit(messageIndex: 2, start: 8, length: 8),
            ConversationHit(messageIndex: 2, start: 21, length: 8),
        ])
    }

    func testHitLocationsAreCaseInsensitive() {
        let hits = ConversationHits.locations(messageTexts: ["Worktree WORKTREE worktree"], terms: ["worktree"])
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.map(\.start), [0, 9, 18])
    }

    func testHitLocationsMultipleTermsHighlightAll() {
        // AND semantics select the conversation (server side); the app
        // highlights every term's occurrences.
        let hits = ConversationHits.locations(messageTexts: ["keep on top of the worktree"], terms: ["keep", "worktree"])
        XCTAssertEqual(hits.map(\.start), [0, 19])
    }

    func testHitLocationsDedupeIdenticalSpans() {
        // Two terms matching the exact same span count once.
        let hits = ConversationHits.locations(messageTexts: ["worktree"], terms: ["work", "work"])
        XCTAssertEqual(hits.count, 1)
    }

    func testHitLocationsCharacterOffsetsWithMultibyteText() {
        // Offsets are CHARACTER offsets, so two multibyte characters (U+4F1A
        // U+8A71, written as escapes to keep the source ASCII) plus a space
        // put the match at character offset 3, not a larger byte offset.
        let hits = ConversationHits.locations(messageTexts: ["\u{4f1a}\u{8a71} worktree"], terms: ["worktree"])
        XCTAssertEqual(hits, [ConversationHit(messageIndex: 0, start: 3, length: 8)])
    }

    // MARK: - Folding (§9)

    func testIsFoldedAtBoundary() {
        let limit = ConversationsConstants.messageFoldCharacterLimit
        XCTAssertFalse(ConversationHits.isFolded(String(repeating: "a", count: limit)))
        XCTAssertTrue(ConversationHits.isFolded(String(repeating: "a", count: limit + 1)))
    }

    func testFoldedPrefixIsFirstLimitCharacters() {
        let limit = ConversationsConstants.messageFoldCharacterLimit
        let text = String(repeating: "a", count: limit) + "TAIL"
        XCTAssertEqual(ConversationHits.foldedPrefix(text).count, limit)
    }

    func testRequiresExpansionForHitPastFold() {
        let limit = ConversationsConstants.messageFoldCharacterLimit
        let text = String(repeating: "a", count: limit + 100) + "worktree"
        // A hit fully inside the visible prefix does not need expansion.
        XCTAssertFalse(ConversationHits.requiresExpansion(
            hit: ConversationHit(messageIndex: 0, start: 0, length: 8),
            messageText: text
        ))
        // A hit past the fold needs the message expanded.
        XCTAssertTrue(ConversationHits.requiresExpansion(
            hit: ConversationHit(messageIndex: 0, start: limit + 100, length: 8),
            messageText: text
        ))
    }

    func testShortMessageNeverRequiresExpansion() {
        XCTAssertFalse(ConversationHits.requiresExpansion(
            hit: ConversationHit(messageIndex: 0, start: 0, length: 2),
            messageText: "short"
        ))
    }
}
