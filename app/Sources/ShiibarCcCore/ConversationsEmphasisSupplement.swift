// Conservative emphasis supplement (DESIGN.md §4.6 "emphasis supplement",
// §8.38): the standard parser refuses emphasis whose markers touch CJK
// punctuation and brackets (CommonMark flanking rules — constant in Japanese
// conversations), leaving literal "**" on screen. After the standard parse,
// markers it left literal are supplemented — but ONLY unambiguous balanced
// pairs; nesting or any ambiguity keeps the markers literal (a miss is
// preferred over a false positive).
//
// This runs while inline content is built, BEFORE a block's rendered text
// is derived — so the rendered text (the §4.6 hit/fold coordinate space)
// already reflects the supplement, and highlights can never drift.

import Foundation

public enum ConversationsEmphasisSupplement {
    /// Supplement literal emphasis pairs in a post-parse inline fragment.
    /// Marker kinds: "**" (bold), "~~" (strikethrough), "*" (italic) — the
    /// two-character markers are resolved first so a lone "*" candidate can
    /// never be half of a "**".
    public static func apply(_ source: AttributedString) -> AttributedString {
        var result = source
        result = supplement(markerCharacter: "*", runLength: 2, intent: .stronglyEmphasized, in: result)
        result = supplement(markerCharacter: "~", runLength: 2, intent: .strikethrough, in: result)
        result = supplement(markerCharacter: "*", runLength: 1, intent: .emphasized, in: result)
        return result
    }

    // MARK: - One marker kind

    private static func supplement(
        markerCharacter: Character, runLength: Int,
        intent: InlinePresentationIntent, in source: AttributedString
    ) -> AttributedString {
        let characters = Array(String(source.characters))
        guard characters.contains(markerCharacter) else { return source }
        let codeRanges = intentRanges(in: source) { $0.contains(.code) }
        let emphasisRanges = intentRanges(in: source) {
            !$0.intersection([.stronglyEmphasized, .emphasized, .strikethrough]).isEmpty
        }

        // Candidates: marker-character runs of EXACTLY the wanted length
        // (a run of 3+ is ambiguous and never a candidate), outside code
        // spans (backticked markers are literal by design).
        var candidates: [Int] = [] // start offset of each marker occurrence
        var index = 0
        while index < characters.count {
            guard characters[index] == markerCharacter else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < characters.count, characters[runEnd] == markerCharacter { runEnd += 1 }
            let run = runEnd - index
            if run == runLength, !codeRanges.contains(where: { $0.overlaps(index..<runEnd) }) {
                candidates.append(index)
            }
            index = runEnd
        }

        // Balanced and unambiguous only: an odd count means an unpaired
        // marker somewhere — supplement nothing (§4.6).
        guard candidates.count >= 2, candidates.count.isMultiple(of: 2) else { return source }

        // Sequential pairs, each validated; ANY doubtful pair keeps the
        // whole fragment literal (all-or-nothing conservatism).
        var pairs: [(open: Int, close: Int)] = []
        for pairIndex in stride(from: 0, to: candidates.count, by: 2) {
            let open = candidates[pairIndex]
            let close = candidates[pairIndex + 1]
            let content = (open + runLength)..<close
            guard !content.isEmpty else { return source }
            // No emphasis characters inside: rules out nesting and any
            // ambiguous pairing.
            guard !characters[content].contains(where: { $0 == "*" || $0 == "~" }) else { return source }
            // No pre-existing emphasis inside: the parser sometimes
            // mis-pairs across CJK blockers (measured), leaving markers
            // whose span crosses an already-emphasized run — supplementing
            // there would merge distinct emphases into one.
            guard !emphasisRanges.contains(where: { $0.overlaps(content) }) else { return source }
            pairs.append((open, close))
        }

        // Rebuild: drop the marker characters, add the intent over each
        // pair's content, keep everything else (including existing
        // attributes like code spans inside the content) untouched.
        var rebuilt = AttributedString()
        var cursor = 0
        for pair in pairs {
            rebuilt.append(slice(source, from: cursor, to: pair.open))
            var content = slice(source, from: pair.open + runLength, to: pair.close)
            addIntent(intent, to: &content)
            rebuilt.append(content)
            cursor = pair.close + runLength
        }
        rebuilt.append(slice(source, from: cursor, to: characters.count))
        return rebuilt
    }

    // MARK: - AttributedString helpers (Character offsets)

    private static func slice(_ source: AttributedString, from: Int, to: Int) -> AttributedString {
        guard to > from else { return AttributedString() }
        let characters = source.characters
        guard let lower = characters.index(
            characters.startIndex, offsetBy: from, limitedBy: characters.endIndex
        ), let upper = characters.index(
            lower, offsetBy: to - from, limitedBy: characters.endIndex
        ) else { return AttributedString() }
        return AttributedString(source[lower..<upper])
    }

    private static func addIntent(_ intent: InlinePresentationIntent, to content: inout AttributedString) {
        // Collect run spans first — mutating attributes invalidates the run
        // indices being walked (same discipline as the app's styling pass).
        var spans: [(start: Int, length: Int, existing: InlinePresentationIntent?)] = []
        var cursor = 0
        for run in content.runs {
            let length = content.characters.distance(from: run.range.lowerBound, to: run.range.upperBound)
            spans.append((cursor, length, run.inlinePresentationIntent))
            cursor += length
        }
        for span in spans {
            let characters = content.characters
            guard let lower = characters.index(
                characters.startIndex, offsetBy: span.start, limitedBy: characters.endIndex
            ), let upper = characters.index(
                lower, offsetBy: span.length, limitedBy: characters.endIndex
            ) else { continue }
            var merged = span.existing ?? []
            merged.insert(intent)
            content[lower..<upper].inlinePresentationIntent = merged
        }
    }

    /// Character-offset ranges of runs whose intent satisfies `predicate`.
    private static func intentRanges(
        in source: AttributedString, where predicate: (InlinePresentationIntent) -> Bool
    ) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var cursor = 0
        for run in source.runs {
            let length = source.characters.distance(from: run.range.lowerBound, to: run.range.upperBound)
            if let intent = run.inlinePresentationIntent, predicate(intent) {
                ranges.append(cursor..<(cursor + length))
            }
            cursor += length
        }
        return ranges
    }
}
