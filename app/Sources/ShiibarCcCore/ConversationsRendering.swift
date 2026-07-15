// Markdown block splitting and rendered-text math for the Conversations
// window's right pane (DESIGN.md §4.6 "rendering grammar"). A user message is
// a full-width band shown verbatim (no Markdown); a Claude message is split
// into blocks — fenced code blocks / headings / bullet and numbered list
// items / pipe tables / paragraphs — and inline styles (code, bold, italic,
// strikethrough, links) come from Foundation's markdown parser. Out-of-scope
// constructs (blockquotes, ...) stay as plain paragraph text, and a failed
// inline parse falls back to the literal text — rendering never fails hard
// (§4.6).
//
// The "rendered text" — the characters actually visible after Markdown
// consumption — is the domain for hit offsets and the fold boundary (§4.6:
// the CLI filters conversations on raw text; in-document positioning uses
// the displayed text). Fonts, colors, and highlight backgrounds are applied
// by the view (ShiibarCcApp); everything here is presentation-independent
// and unit-tested.

import Foundation

/// One cell of a pipe table (§4.6/§8.37): its inline-styled content and
/// where its visible characters start within the table BLOCK's rendered
/// text. Pipes, the separator row, and formatting whitespace are syntax and
/// never enter the rendered text — hits and the fold boundary see only cell
/// characters, joined row-major with one "\n" per boundary (the same
/// one-character-join style as the block join, so a whitespace-free search
/// term can never span cells).
public struct TableCell: Equatable {
    /// Inline-styled cell content (the same Foundation markdown intents as
    /// paragraphs; fonts and highlight backgrounds are the view's job).
    public let text: AttributedString
    /// The cell's visible characters (`String(text.characters)`).
    public let renderedText: String
    /// Character offset of this cell's first character within the table
    /// block's rendered text.
    public let startOffset: Int

    public init(text: AttributedString, startOffset: Int) {
        self.text = text
        self.renderedText = String(text.characters)
        self.startOffset = startOffset
    }
}

/// One rendered block of a message, in document order.
public struct MessageBlock: Equatable {
    public enum Kind: Equatable {
        /// A user message shown verbatim in the full-width band (§4.6 —
        /// no Markdown rendering for the user's own words).
        case userText
        case paragraph
        /// ATX heading, level 1...6.
        case heading(level: Int)
        /// Fenced code block content (fences and info string consumed).
        case codeBlock
        /// One list item (bullet or ordered); `indent` is the nesting depth
        /// derived from leading indentation (0 = top level).
        case listItem(indent: Int)
        /// A GitHub-style pipe table (§4.6/§8.37): `rows[0]` is the header
        /// row; the separator row is consumed and never appears. Rows may
        /// have differing cell counts — a broken table renders as best it
        /// can. The block's `text`/`renderedText` is the cells' joined
        /// visible text, so all block-level math (offsets, fold) applies
        /// unchanged.
        case table(rows: [[TableCell]])
    }

    public let kind: Kind
    /// The visible content with inline presentation intents from Foundation's
    /// markdown parser (bold / italic / code / strikethrough / links). Fonts
    /// and highlight backgrounds are the view's job.
    public let text: AttributedString
    /// The visible characters (`String(text.characters)`) — the coordinate
    /// space of hit offsets and the fold boundary (§4.6 rendered text).
    public let renderedText: String

    public init(kind: Kind, text: AttributedString) {
        self.kind = kind
        self.text = text
        self.renderedText = String(text.characters)
    }
}

/// One message prepared for display: its block sequence, the joined rendered
/// text (blocks joined with "\n"), and each block's start offset into that
/// text. Hits are computed on `renderedText`; a hit can never span a block
/// boundary because search terms contain no whitespace (§4.6) and the block
/// separator is a newline.
public struct RenderedMessage: Equatable {
    public let blocks: [MessageBlock]
    public let renderedText: String
    public let blockStartOffsets: [Int]

    public init(role: String, text: String) {
        let blocks = ConversationsRendering.blocks(role: role, text: text)
        self.blocks = blocks
        self.renderedText = ConversationsRendering.joinedRenderedText(blocks)
        self.blockStartOffsets = ConversationsRendering.blockStartOffsets(blocks)
    }
}

public enum ConversationsRendering {
    // MARK: - Block splitting

    /// Split one message into rendered blocks. User messages are one verbatim
    /// `userText` block (§4.6: the band carries the words unrendered); any
    /// other role (assistant) is split as Markdown.
    public static func blocks(role: String, text: String) -> [MessageBlock] {
        if role == "user" {
            if text.isEmpty { return [] }
            return [MessageBlock(kind: .userText, text: AttributedString(text))]
        }
        return markdownBlocks(text)
    }

    /// The joined visible text of a block sequence — blocks separated by one
    /// "\n" — used for hit computation and the fold boundary (§4.6).
    public static func joinedRenderedText(_ blocks: [MessageBlock]) -> String {
        blocks.map(\.renderedText).joined(separator: "\n")
    }

    /// Start offset (in characters of the joined rendered text) of each
    /// block, accounting for the one-character separators.
    public static func blockStartOffsets(_ blocks: [MessageBlock]) -> [Int] {
        var offsets: [Int] = []
        var cursor = 0
        for block in blocks {
            offsets.append(cursor)
            cursor += block.renderedText.count + 1
        }
        return offsets
    }

    /// Total length of the joined rendered text for the given block lengths.
    public static func totalRenderedLength(blockLengths: [Int]) -> Int {
        guard !blockLengths.isEmpty else { return 0 }
        return blockLengths.reduce(0, +) + (blockLengths.count - 1)
    }

    // MARK: - Fold boundary (§4.6/§9: counted on rendered text)

    /// Per-block visible character counts when a message is folded: the first
    /// `limit` characters of the joined rendered text, cut without breaking
    /// the block sequence (§4.6 — a partially visible block is truncated
    /// rendered content of the same kind, so it still renders as that block).
    /// Returns nil when the message is not folded (total length <= limit).
    public static func foldedVisibleLengths(blockLengths: [Int], limit: Int) -> [Int]? {
        guard totalRenderedLength(blockLengths: blockLengths) > limit else { return nil }
        var visible: [Int] = []
        var cursor = 0
        for length in blockLengths {
            visible.append(max(0, min(length, limit - cursor)))
            cursor += length + 1
        }
        return visible
    }

    // MARK: - Markdown scanning (assistant messages)

    /// Line-based block scanner for the §4.6 rendering scope: fenced code
    /// blocks, ATX headings, bullet/numbered list items, pipe tables,
    /// paragraphs. Anything else (blockquotes, indented code, setext
    /// headings, HTML) falls into paragraphs with its marker characters left
    /// visible — out-of-scope constructs stay plain text (§4.6).
    private static func markdownBlocks(_ text: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let source = paragraphLines.joined(separator: "\n")
            blocks.append(MessageBlock(kind: .paragraph, text: inlineAttributed(source)))
            paragraphLines = []
        }

        let lines = text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]

            if let fence = fenceMarker(line) {
                flushParagraph()
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !isClosingFence(lines[index], open: fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 } // consume the closing fence
                let code = codeLines.joined(separator: "\n")
                blocks.append(MessageBlock(kind: .codeBlock, text: AttributedString(code)))
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = headingMarker(line) {
                flushParagraph()
                blocks.append(MessageBlock(
                    kind: .heading(level: heading.level),
                    text: inlineAttributed(heading.content)
                ))
                index += 1
                continue
            }

            if let item = listItemMarker(line) {
                flushParagraph()
                var itemText = AttributedString(item.marker)
                itemText.append(inlineAttributed(item.content))
                blocks.append(MessageBlock(kind: .listItem(indent: item.indent), text: itemText))
                index += 1
                continue
            }

            // Pipe table (§4.6/§8.37): a pipe-containing header line
            // immediately followed by a separator row. Without the separator
            // row, a pipe-containing line is NOT a table and stays a
            // paragraph.
            if line.contains("|"), index + 1 < lines.count,
               isTableSeparatorLine(lines[index + 1]),
               splitTableRow(lines[index + 1]).count == splitTableRow(line).count {
                flushParagraph()
                var dataLines: [String] = []
                var next = index + 2
                // Data rows continue while lines keep the table shape
                // (non-blank, pipe-containing).
                while next < lines.count, lines[next].contains("|"),
                      !lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                    dataLines.append(lines[next])
                    next += 1
                }
                blocks.append(tableBlock(headerLine: line, dataLines: dataLines))
                index = next
                continue
            }

            paragraphLines.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Pipe tables (§4.6/§8.37)

    /// Per-cell visible character counts when only the first `visibleLength`
    /// characters of the table block's rendered text are shown (a fold cut
    /// landing mid-table): fully visible cells keep their length, the
    /// straddling cell shows its prefix, later cells drop to 0 — the same
    /// rule as block truncation, applied at cell granularity (§4.6).
    public static func visibleTableCellLengths(rows: [[TableCell]], visibleLength: Int) -> [[Int]] {
        rows.map { row in
            row.map { cell in
                max(0, min(cell.renderedText.count, visibleLength - cell.startOffset))
            }
        }
    }

    /// Build one table block: header + data rows, each split into cells that
    /// go through the same inline parser as paragraphs. The block's rendered
    /// text is the cells' visible characters joined row-major with one "\n"
    /// per boundary; each cell records its start offset so hit offsets map
    /// into cells. Broken shapes (differing cell counts, empty cells) are
    /// kept as-is (§4.6: render what can be read).
    private static func tableBlock(headerLine: String, dataLines: [String]) -> MessageBlock {
        var rows: [[TableCell]] = []
        var joined = ""
        var isFirstCell = true
        for line in [headerLine] + dataLines {
            var row: [TableCell] = []
            for source in splitTableRow(line) {
                if !isFirstCell { joined.append("\n") }
                isFirstCell = false
                let cell = TableCell(text: inlineAttributed(source), startOffset: joined.count)
                joined.append(cell.renderedText)
                row.append(cell)
            }
            rows.append(row)
        }
        return MessageBlock(kind: .table(rows: rows), text: AttributedString(joined))
    }

    /// A table separator row: only pipes, hyphens, colons, and whitespace,
    /// with at least one hyphen (alignment colons are consumed — all columns
    /// render left-aligned, §4.6). The caller additionally requires its cell
    /// count to match the header's (the GitHub rule) so a thematic-break
    /// "---" after a pipe-containing sentence can't fake a table.
    private static func isTableSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " || $0 == "\t" }
    }

    /// Split one table line into cell sources: surrounding whitespace and
    /// one leading/trailing pipe are consumed, the rest splits on unescaped
    /// pipes, each cell is trimmed (formatting whitespace is syntax — §4.6),
    /// and "\|" unescapes to "|" here at table-split time — the GitHub rule,
    /// which applies even inside code spans (the inline parser would not
    /// unescape there).
    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        if trimmed.first == "|" { trimmed = trimmed.dropFirst() }
        if trimmed.last == "|", !trimmed.hasSuffix("\\|") { trimmed = trimmed.dropLast() }

        var cells: [String] = []
        var current = ""
        var previousWasEscape = false
        for character in trimmed {
            if character == "|", !previousWasEscape {
                cells.append(current)
                current = ""
                previousWasEscape = false
                continue
            }
            current.append(character)
            previousWasEscape = (character == "\\") && !previousWasEscape
        }
        cells.append(current)
        return cells.map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\|", with: "|")
        }
    }

    /// Inline markdown (code / bold / italic / strikethrough / links) via
    /// Foundation's parser, preserving whitespace and newlines, followed by
    /// the conservative emphasis supplement (§4.6: markers the parser left
    /// literal next to CJK punctuation become emphasis when the pairing is
    /// unambiguous). The supplement runs HERE, before the block's rendered
    /// text is derived, so hit and fold coordinates match the display. A
    /// parse failure falls back to the literal text — a message never fails
    /// to render (§4.6).
    private static func inlineAttributed(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
        return ConversationsEmphasisSupplement.apply(parsed)
    }

    /// An opening fence: up to 3 leading spaces, then 3+ backticks or tildes.
    /// A backtick fence's info string must not contain a backtick (CommonMark).
    private static func fenceMarker(_ line: String) -> (char: Character, length: Int)? {
        let leadingSpaces = line.prefix(while: { $0 == " " })
        guard leadingSpaces.count <= 3 else { return nil }
        let rest = line.dropFirst(leadingSpaces.count)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        if first == "`", rest.dropFirst(run).contains("`") { return nil }
        return (first, run)
    }

    /// A closing fence: the opening character repeated at least as many
    /// times, nothing else on the line (whitespace allowed).
    private static func isClosingFence(_ line: String, open: (char: Character, length: Int)) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= open.length else { return false }
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return false }
        return trimmed.allSatisfy { $0 == open.char }
    }

    /// An ATX heading: up to 3 leading spaces, 1-6 "#", then a space (or end
    /// of line). Returns the level and the trimmed content.
    private static func headingMarker(_ line: String) -> (level: Int, content: String)? {
        let leadingSpaces = line.prefix(while: { $0 == " " })
        guard leadingSpaces.count <= 3 else { return nil }
        let rest = line.dropFirst(leadingSpaces.count)
        let hashes = rest.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let after = rest.dropFirst(hashes.count)
        if after.isEmpty { return (hashes.count, "") }
        guard after.first == " " else { return nil }
        return (hashes.count, String(after.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// A list item: optional indentation, then a bullet ("-", "*", "+") or an
    /// ordered marker (1-9 digits + "." or ")"), followed by a space. The
    /// bullet renders as U+2022; the ordered marker keeps its literal number
    /// and delimiter. Indent depth = indentation columns / 2 (tab = 4),
    /// capped at 6.
    private static func listItemMarker(_ line: String) -> (indent: Int, marker: String, content: String)? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let columns = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let indent = min(columns / 2, 6)
        let rest = line.dropFirst(leading.count)

        if let first = rest.first, first == "-" || first == "*" || first == "+",
           rest.dropFirst().first == " " {
            return (indent, "\u{2022} ", String(rest.dropFirst(2)))
        }

        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return (indent, "\(digits)\(delimiter) ", String(afterDigits.dropFirst(2)))
    }
}
