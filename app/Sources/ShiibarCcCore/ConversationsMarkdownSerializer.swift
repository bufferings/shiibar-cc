// "Copy as Markdown" serialization (DESIGN.md §4.6 "selection and copy",
// §8.38): given a selection range in a message's RENDERED text, write back
// Markdown from the block structure and inline styles the display was built
// from — headings, list items, code blocks (re-fenced), tables, and inline
// code / bold / italic / strikethrough / links are restored; a selection
// cutting into a block serializes just that part. This is deliberately "the
// Markdown expression of what you selected", not a byte slice of the
// original transcript (rendered text and raw text have no character
// correspondence once markers are consumed).
//
// The page reports selection ranges in UTF-16 units (JS coordinates); the
// caller converts them to Character offsets with `characterOffset` before
// serializing (the same boundary discipline as the payload, §8.38).

import Foundation

public enum ConversationsMarkdownSerializer {
    /// Markdown for the [start, end) slice (rendered-text Character offsets)
    /// of one rendered message. Returns "" for an empty/invalid range.
    public static func markdown(rendered: RenderedMessage, start: Int, end: Int) -> String {
        let total = rendered.renderedText.count
        let clampedStart = max(0, min(start, total))
        let clampedEnd = max(clampedStart, min(end, total))
        guard clampedEnd > clampedStart else { return "" }

        var pieces: [(isListItem: Bool, text: String)] = []
        for (index, block) in rendered.blocks.enumerated() {
            let blockStart = rendered.blockStartOffsets[index]
            let length = block.renderedText.count
            let localStart = max(0, clampedStart - blockStart)
            let localEnd = min(length, clampedEnd - blockStart)
            guard localEnd > localStart else { continue }
            if let piece = serializeBlock(block, from: localStart, to: localEnd) {
                pieces.append(piece)
            }
        }

        var out = ""
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                // Adjacent list items stay one list; everything else is a
                // blank-line-separated block.
                out += (pieces[index - 1].isListItem && piece.isListItem) ? "\n" : "\n\n"
            }
            out += piece.text
        }
        return out
    }

    /// UTF-16 offset (JS selection coordinates) -> Character offset, snapped
    /// DOWN to the nearest Character boundary (a selection can end inside a
    /// grapheme cluster; shrinking beats overshooting).
    public static func characterOffset(utf16Offset: Int, in text: String) -> Int {
        let clamped = max(0, min(utf16Offset, text.utf16.count))
        var candidate = clamped
        while candidate > 0 {
            if let utf16Index = text.utf16.index(
                text.utf16.startIndex, offsetBy: candidate, limitedBy: text.utf16.endIndex
            ), let index = String.Index(utf16Index, within: text) {
                return text.distance(from: text.startIndex, to: index)
            }
            candidate -= 1
        }
        return 0
    }

    // MARK: - Blocks

    private static func serializeBlock(_ block: MessageBlock, from: Int, to: Int) -> (isListItem: Bool, text: String)? {
        switch block.kind {
        case .userText:
            // The user's words are verbatim — the rendered slice IS the raw
            // slice.
            return (false, sliceText(block.renderedText, from: from, to: to))
        case .paragraph:
            return (false, inlineMarkdown(block.text, from: from, to: to))
        case .heading(let level):
            // The heading marker returns only when the slice starts at the
            // block head (a mid-heading fragment is just text).
            let prefix = from == 0 ? String(repeating: "#", count: level) + " " : ""
            return (false, prefix + inlineMarkdown(block.text, from: from, to: to))
        case .codeBlock:
            // Always re-fence, partial or not — the fragment is code.
            return (false, "```\n" + sliceText(block.renderedText, from: from, to: to) + "\n```")
        case .listItem(let indent):
            return (true, serializeListItem(block, indent: indent, from: from, to: to))
        case .table(let rows):
            return (false, serializeTable(rows, from: from, to: to))
        }
    }

    private static func serializeListItem(_ block: MessageBlock, indent: Int, from: Int, to: Int) -> String {
        // Rendered text = visible marker + inline content (M36/M38): a
        // bullet renders "\u{2022} " (restored as "- "), an ordered marker
        // keeps its literal number and delimiter.
        let text = block.renderedText
        var markerLength = 0
        var markdownMarker = ""
        if text.hasPrefix("\u{2022} ") {
            markerLength = 2
            markdownMarker = "- "
        } else {
            let digits = text.prefix(while: { $0.isNumber })
            let rest = text.dropFirst(digits.count)
            if !digits.isEmpty, let delimiter = rest.first, delimiter == "." || delimiter == ")",
               rest.dropFirst().first == " " {
                markerLength = digits.count + 2
                markdownMarker = "\(digits)\(delimiter) "
            }
        }
        // The marker returns when the slice touches it; a slice starting
        // inside the content is plain inline text.
        if from < markerLength {
            let contentEnd = max(markerLength, to)
            return String(repeating: "  ", count: indent) + markdownMarker
                + inlineMarkdown(block.text, from: markerLength, to: contentEnd)
        }
        return inlineMarkdown(block.text, from: from, to: to)
    }

    private static func serializeTable(_ rows: [[TableCell]], from: Int, to: Int) -> String {
        var lines: [String] = []
        var headerIncluded = false
        var headerColumns = 0
        var dataIncluded = false
        for (rowIndex, row) in rows.enumerated() {
            var cells: [String] = []
            for cell in row {
                let cellStart = cell.startOffset
                let length = cell.renderedText.count
                let localStart = max(0, from - cellStart)
                let localEnd = min(length, to - cellStart)
                // An empty cell inside the selected span keeps its slot.
                guard localEnd > localStart || (length == 0 && cellStart >= from && cellStart < to) else { continue }
                // Literal pipes inside a cell must survive the round trip.
                cells.append(
                    inlineMarkdown(cell.text, from: localStart, to: max(localStart, localEnd))
                        .replacingOccurrences(of: "|", with: "\\|")
                )
            }
            guard !cells.isEmpty else { continue }
            if rowIndex == 0 {
                headerIncluded = true
                headerColumns = cells.count
            } else {
                dataIncluded = true
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        // A separator row only when the fragment is shaped like a table
        // (header + data); a cells-only fragment stays a single pipe row.
        if headerIncluded, dataIncluded, headerColumns > 0 {
            lines.insert("|" + String(repeating: "---|", count: headerColumns), at: 1)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Inline styles

    /// The [from, to) Character slice of an inline-styled fragment, with the
    /// §4.6 inline set restored: `code`, **bold**, *italic*, ~~strike~~,
    /// [links](url). Runs sharing one link URL serialize as a single link.
    private static func inlineMarkdown(_ attributed: AttributedString, from: Int, to: Int) -> String {
        // Collect intersecting runs as (text, intent, link) in order.
        var runs: [(text: String, intent: InlinePresentationIntent?, link: String?)] = []
        var cursor = 0
        for run in attributed.runs {
            let piece = String(attributed.characters[run.range])
            let runStart = cursor
            let runEnd = cursor + piece.count
            cursor = runEnd
            let sliceStart = max(from, runStart)
            let sliceEnd = min(to, runEnd)
            guard sliceEnd > sliceStart else { continue }
            let text = sliceText(piece, from: sliceStart - runStart, to: sliceEnd - runStart)
            runs.append((text, run.inlinePresentationIntent, run.link?.absoluteString))
        }

        // Group consecutive runs that share a link so "[**a** b](url)"
        // serializes as one link.
        var out = ""
        var index = 0
        while index < runs.count {
            if let href = runs[index].link {
                var inner = ""
                while index < runs.count, runs[index].link == href {
                    inner += styledText(runs[index].text, intent: runs[index].intent)
                    index += 1
                }
                out += "[\(inner)](\(href))"
            } else {
                out += styledText(runs[index].text, intent: runs[index].intent)
                index += 1
            }
        }
        return out
    }

    private static func styledText(_ text: String, intent: InlinePresentationIntent?) -> String {
        guard let intent, !text.isEmpty else { return text }
        if intent.contains(.code) { return "`\(text)`" }
        var result = text
        if intent.contains(.emphasized) { result = "*\(result)*" }
        if intent.contains(.stronglyEmphasized) { result = "**\(result)**" }
        if intent.contains(.strikethrough) { result = "~~\(result)~~" }
        return result
    }

    private static func sliceText(_ text: String, from: Int, to: Int) -> String {
        guard to > from else { return "" }
        let start = text.index(text.startIndex, offsetBy: min(from, text.count))
        let end = text.index(text.startIndex, offsetBy: min(to, text.count))
        return String(text[start..<end])
    }
}
