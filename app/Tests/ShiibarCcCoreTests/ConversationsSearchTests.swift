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

    // MARK: - Folding (§9, counted on rendered text)

    func testIsFoldedAtBoundary() {
        let limit = ConversationsConstants.messageFoldCharacterLimit
        XCTAssertFalse(ConversationHits.isFolded(String(repeating: "a", count: limit)))
        XCTAssertTrue(ConversationHits.isFolded(String(repeating: "a", count: limit + 1)))
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

    // MARK: - Hidden-hit count and badge (§4.6)

    func testHiddenHitCountCountsHitsPastVisibleLimit() {
        let hits = [
            ConversationHit(messageIndex: 1, start: 0, length: 3), // fully visible
            ConversationHit(messageIndex: 1, start: 98, length: 5), // straddles the boundary — hidden
            ConversationHit(messageIndex: 1, start: 200, length: 3), // fully hidden
            ConversationHit(messageIndex: 2, start: 300, length: 3), // other message — ignored
        ]
        XCTAssertEqual(ConversationHits.hiddenHitCount(hits: hits, messageIndex: 1, visibleLimit: 100), 2)
    }

    func testHiddenHitCountBoundaryIsExclusive() {
        // A hit ending exactly at the visible limit is fully visible.
        let hits = [ConversationHit(messageIndex: 0, start: 95, length: 5)]
        XCTAssertEqual(ConversationHits.hiddenHitCount(hits: hits, messageIndex: 0, visibleLimit: 100), 0)
        XCTAssertEqual(ConversationHits.hiddenHitCount(hits: hits, messageIndex: 0, visibleLimit: 99), 1)
    }

    func testMatchBadgeTextSingularPluralAndNone() {
        // §4.6: "N matches", singular "1 match", no badge for zero.
        XCTAssertNil(ConversationHits.matchBadgeText(count: 0))
        XCTAssertEqual(ConversationHits.matchBadgeText(count: 1), "1 match")
        XCTAssertEqual(ConversationHits.matchBadgeText(count: 2), "2 matches")
    }

    // MARK: - Hit tick marks (§4.6)

    func testTickFractionsUseContainingMessagePosition() {
        // Four messages of equal visible length: a hit in message 0 sits at
        // the center of the first quarter, one in message 3 at the center of
        // the last quarter.
        let hits = [
            ConversationHit(messageIndex: 0, start: 0, length: 2),
            ConversationHit(messageIndex: 3, start: 0, length: 2),
        ]
        let fractions = ConversationTicks.fractions(hits: hits, visibleMessageLengths: [100, 100, 100, 100])
        XCTAssertEqual(fractions, [0.125, 0.875])
    }

    func testTickFractionsHitsInOneMessageOverlap() {
        // §4.6: ticks for multiple hits in one message may overlap — the
        // approximation is per message, so they are identical.
        let hits = [
            ConversationHit(messageIndex: 1, start: 0, length: 2),
            ConversationHit(messageIndex: 1, start: 50, length: 2),
        ]
        let fractions = ConversationTicks.fractions(hits: hits, visibleMessageLengths: [100, 100])
        XCTAssertEqual(fractions[0], fractions[1])
        XCTAssertEqual(fractions[0], 0.75)
    }

    func testTickFractionsWeightedByVisibleLengths() {
        // A long first message pushes the second message's tick down.
        let hits = [ConversationHit(messageIndex: 1, start: 0, length: 2)]
        let fractions = ConversationTicks.fractions(hits: hits, visibleMessageLengths: [300, 100])
        XCTAssertEqual(fractions, [0.875]) // (300 + 50) / 400
    }

    func testTickFractionsEmptyAndOutOfRangeAreSafe() {
        XCTAssertEqual(ConversationTicks.fractions(hits: [], visibleMessageLengths: []), [])
        // An out-of-range message index degrades to mid-document, not a crash.
        let hits = [ConversationHit(messageIndex: 9, start: 0, length: 2)]
        XCTAssertEqual(ConversationTicks.fractions(hits: hits, visibleMessageLengths: [100]), [0.5])
    }
}
