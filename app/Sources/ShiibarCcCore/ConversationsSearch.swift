// Client-side search logic for the Conversations window (DESIGN.md §4.6):
// deciding when a typed query becomes a real `conversations search` (vs
// staying on the browse list), and computing in-body hit locations for the
// preview's hit navigation. The subprocess call and the SwiftUI rendering
// live in ShiibarCcApp; the decisions and the offset math live here so they
// can be unit-tested table-style.

import Foundation

/// Tunable numbers for the Conversations window, pinned to DESIGN.md §9 by a
/// test. The `NSBackgroundActivityScheduler`/subprocess wiring lives in
/// ShiibarCcApp (AppKit, not unit-testable in this target).
public enum ConversationsConstants {
    /// §9: UI search debounce — the delay before the keystroke launches a
    /// `conversations search` subprocess (200ms).
    public static let searchDebounceSeconds: Double = 0.2
    /// §9: a message longer than this many characters is folded behind
    /// `Show full message` (the DB still holds the full text).
    public static let messageFoldCharacterLimit: Int = 500

    /// §9: the sidebar starts at 250pt and drags between 200 and 400pt
    /// (§8.38(7); the width is remembered in UserDefaults).
    public static let sidebarInitialWidth: Double = 250
    public static let sidebarMinimumWidth: Double = 200
    public static let sidebarMaximumWidth: Double = 400

    public static func clampSidebarWidth(_ width: Double) -> Double {
        min(max(width, sidebarMinimumWidth), sidebarMaximumWidth)
    }
}

/// The query-term rules the app shares with the CLI search (§4.6): trim
/// surrounding whitespace (ASCII and full-width), split on whitespace into
/// words, and keep only words of 2+ characters. If nothing valid remains,
/// the app stays on the browse list and issues no search (§4.6 — "don't
/// silently return zero results", so an all-too-short query is browse, not
/// an empty search).
public enum ConversationsQuery {
    /// Valid search terms (2+ characters) in the raw query, in order.
    public static func validTerms(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    /// Whether a real `conversations search <query>` should be issued for
    /// this raw query. False = stay on browse (empty-query list).
    public static func shouldIssueSearch(_ raw: String) -> Bool {
        !validTerms(raw).isEmpty
    }
}

/// One occurrence of a search term in the preview body. Offsets are in the
/// message's RENDERED text — the characters visible after Markdown
/// consumption (§4.6): the CLI filters conversations on raw text; positioning
/// within the document uses the displayed text.
public struct ConversationHit: Equatable {
    /// Index into the displayed `messages` array (document order).
    public let messageIndex: Int
    /// Character offset of the match start within that message's rendered text.
    public let start: Int
    /// Match length in characters.
    public let length: Int

    public init(messageIndex: Int, start: Int, length: Int) {
        self.messageIndex = messageIndex
        self.start = start
        self.length = length
    }
}

/// In-body hit navigation math (§4.6): after `show`, the app computes every
/// occurrence of each term itself (case-insensitive partial match, the same
/// meaning as the CLI), in document order, over each message's RENDERED text
/// (the characters visible after Markdown consumption — §4.6; a conversation
/// whose only match was in consumed Markdown syntax correctly shows zero
/// in-body hits). All terms highlight in one color; only the current position
/// is emphasized. Folding a long message doesn't hide its hits from the
/// counter — a hit past the fold is still counted and the fold auto-expands
/// when navigated to.
public enum ConversationHits {
    /// Every occurrence of every term across `messageTexts` (the rendered
    /// texts, §4.6), in document order (message order, then character
    /// offset). Case-insensitive, no accent folding (Swift's
    /// `.caseInsensitive` matches the CLI's "case-insensitive partial match,
    /// accents distinct" — §7-6).
    /// Overlapping matches of a single term are counted non-overlapping
    /// (advance past each match); identical spans produced by two terms are
    /// de-duplicated.
    public static func locations(messageTexts: [String], terms: [String]) -> [ConversationHit] {
        var hits: [ConversationHit] = []
        for (messageIndex, text) in messageTexts.enumerated() {
            var perMessage: [ConversationHit] = []
            for term in terms where !term.isEmpty {
                perMessage.append(contentsOf: occurrences(of: term, in: text, messageIndex: messageIndex))
            }
            // Order this message's hits by start, then length, and drop
            // exact-span duplicates from overlapping terms.
            perMessage.sort { ($0.start, $0.length) < ($1.start, $1.length) }
            var seen = Set<Int>() // start*1_000_003 + length, cheap span key
            for hit in perMessage {
                let key = hit.start &* 1_000_003 &+ hit.length
                if seen.insert(key).inserted {
                    hits.append(hit)
                }
            }
        }
        return hits
    }

    /// Whether navigating to `hit` needs the message expanded first: the
    /// message is folded and the hit does not fit entirely within the
    /// visible prefix (§4.6 — folded hits auto-expand on ▲▼ jump).
    /// `messageText` is the message's rendered text (§4.6).
    public static func requiresExpansion(hit: ConversationHit, messageText: String) -> Bool {
        guard isFolded(messageText) else { return false }
        return hit.start + hit.length > ConversationsConstants.messageFoldCharacterLimit
    }

    /// Whether a message is folded: its rendered text (§4.6) is longer than
    /// the §9 limit.
    public static func isFolded(_ text: String) -> Bool {
        text.count > ConversationsConstants.messageFoldCharacterLimit
    }

    /// How many of a folded message's hits are (at least partly) in the
    /// hidden part — hits whose span extends past the visible prefix of
    /// `visibleLimit` rendered characters. Drives the §4.6 count badge next
    /// to "Show full message".
    public static func hiddenHitCount(hits: [ConversationHit], messageIndex: Int, visibleLimit: Int) -> Int {
        hits.filter { $0.messageIndex == messageIndex && $0.start + $0.length > visibleLimit }.count
    }

    /// The §4.6 badge text for hidden hits: "N matches", singular "1 match",
    /// nil when nothing is hidden (no badge).
    public static func matchBadgeText(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 match" : "\(count) matches"
    }

    private static func occurrences(of term: String, in text: String, messageIndex: Int) -> [ConversationHit] {
        guard !term.isEmpty, !text.isEmpty else { return [] }
        var result: [ConversationHit] = []
        var searchStart = text.startIndex
        let termLength = term.count
        while searchStart < text.endIndex,
              let range = text.range(
                  of: term,
                  options: .caseInsensitive,
                  range: searchStart..<text.endIndex
              ) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            result.append(ConversationHit(messageIndex: messageIndex, start: start, length: termLength))
            // Non-overlapping: continue past this match's end.
            searchStart = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
        }
        return result
    }
}

/// Find-bar navigation targets (§4.6/§8.38(7)(8)): WRAPPING at the ends
/// (the ⌘G convention), and ALWAYS producing a target while hits exist —
/// every press scrolls to the current hit even when the index lands on the
/// same place (a single hit wraps onto itself; the round-4 defect was a
/// guard that skipped the jump entirely when the index had nowhere to go).
public enum ConversationsHitNavigation {
    /// ⌘G / the › segment: toward newer hits, wrapping past the newest back
    /// to the oldest.
    public static func next(current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return count - 1 }
        let clamped = min(max(current, 0), count - 1)
        return (clamped + 1) % count
    }

    /// ⇧⌘G / the ‹ segment: toward older hits, wrapping past the oldest back
    /// to the newest.
    public static func previous(current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return count - 1 }
        let clamped = min(max(current, 0), count - 1)
        return (clamped - 1 + count) % count
    }
}

/// Hit tick-mark math (§4.6): while the find bar is visible, the right pane
/// overlays one tick per hit near its right edge, showing the hit
/// distribution over the whole conversation. Positions are a message-level
/// approximation — the containing message's vertical position ratio,
/// estimated by the messages' VISIBLE rendered lengths (a folded message
/// counts its visible prefix only). Ticks of hits in one message may overlap
/// (§4.6 allows it); only the current hit's tick uses the stronger color
/// (the view's job, keyed by hit index).
public enum ConversationTicks {
    /// One fraction (0...1) per hit, in `hits` order: the vertical center of
    /// the containing message over the total, weighted by
    /// `visibleMessageLengths` (one entry per displayed message, in document
    /// order). Zero-length messages weigh 1 so every message occupies some
    /// vertical extent.
    public static func fractions(hits: [ConversationHit], visibleMessageLengths: [Int]) -> [Double] {
        let weights = visibleMessageLengths.map { Double(max($0, 1)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return hits.map { _ in 0.5 } }
        var starts: [Double] = []
        var cursor = 0.0
        for weight in weights {
            starts.append(cursor)
            cursor += weight
        }
        return hits.map { hit in
            guard weights.indices.contains(hit.messageIndex) else { return 0.5 }
            return (starts[hit.messageIndex] + weights[hit.messageIndex] / 2) / total
        }
    }
}
