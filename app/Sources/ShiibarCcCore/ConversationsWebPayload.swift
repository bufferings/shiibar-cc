// The payload contract between Core and the Conversations message page
// (DESIGN.md §4.6 "rendering engine" / §8.38). Core stays authoritative for
// every semantic: rendered text, hit locations, fold boundaries, badge
// counts, and expansion needs are all computed by the existing M36-M38 code
// and only TRANSLATED here — the page cuts and paints at the boundaries it
// receives, it never recomputes them.
//
// All offsets and lengths in the payload are UTF-16 CODE UNITS: JS strings
// index by UTF-16, while Core counts grapheme clusters (Swift Characters) —
// without this boundary conversion every highlight after an emoji or a
// combining sequence would be misaligned (§8.38, found and fixed in the
// spike). Fold cuts are always Character boundaries, so a converted cut can
// never split a surrogate pair.

import Foundation

// MARK: - Payload shape (Encodable; the page's `shiibarAPI.load` input)

public struct WebPanePayload: Encodable, Equatable {
    public let messages: [WebPaneMessage]
    /// Elapsed-time text for the end marker ("Latest message · <elapsed>
    /// ago", §4.6/§8.39), pre-formatted natively with the same rule as the
    /// header. nil = omit the elapsed part.
    public let elapsed: String?
}

public struct WebPaneMessage: Encodable, Equatable {
    public let seq: Int64
    public let role: String
    /// Total rendered length (UTF-16); 0 when the message has no blocks.
    public let len: Int
    /// Whether the message folds (Core rule: rendered text > §9 limit).
    public let folds: Bool
    public let blocks: [WebPaneBlock]
}

public struct WebPaneBlock: Encodable, Equatable {
    /// "user" | "p" | "h" | "code" | "li" | "table"
    public let kind: String
    public let level: Int?
    public let indent: Int?
    /// Rendered text (nil for tables — cells carry their own).
    public let text: String?
    public let runs: [WebPaneRun]?
    /// Start offset within the message's rendered text (UTF-16).
    public let start: Int
    /// Visible UTF-16 length while folded (Core's fold cut, converted).
    public let foldedLen: Int
    public let rows: [[WebPaneCell]]?
}

public struct WebPaneCell: Encodable, Equatable {
    public let text: String
    public let runs: [WebPaneRun]?
    /// Start offset within the MESSAGE's rendered text (UTF-16).
    public let start: Int
    /// Visible UTF-16 length while folded.
    public let foldedLen: Int
}

/// One inline style span (offsets local to its block/cell text, UTF-16).
public struct WebPaneRun: Encodable, Equatable {
    public let s: Int
    public let l: Int
    public let code: Bool?
    public let bold: Bool?
    public let italic: Bool?
    public let strike: Bool?
    public let href: String?
}

/// One hit for `shiibarAPI.setHits` (UTF-16 units, message coordinates).
public struct WebPaneHit: Encodable, Equatable {
    /// Message index (document order).
    public let m: Int
    public let s: Int
    public let l: Int
    /// Core's requiresExpansion — the hit sits (partly) behind the fold.
    /// Drives the badge count and the auto-expand on jump (§4.6).
    public let hidden: Bool
}

// MARK: - Builder

public enum ConversationsWebPayload {
    /// Build the load payload from Core's rendered messages.
    public static func payload(
        messages: [ConversationMessage], rendered: [RenderedMessage], elapsed: String? = nil
    ) -> WebPanePayload {
        var out: [WebPaneMessage] = []
        for (index, message) in messages.enumerated() {
            let renderedMessage = index < rendered.count
                ? rendered[index]
                : RenderedMessage(role: message.role, text: message.text)
            out.append(paneMessage(message, renderedMessage))
        }
        return WebPanePayload(messages: out, elapsed: elapsed)
    }

    /// Hits converted to UTF-16 units + Core's hidden flag.
    public static func hits(_ hits: [ConversationHit], rendered: [RenderedMessage]) -> [WebPaneHit] {
        hits.map { hit in
            guard rendered.indices.contains(hit.messageIndex) else {
                return WebPaneHit(m: hit.messageIndex, s: hit.start, l: hit.length, hidden: false)
            }
            let text = rendered[hit.messageIndex].renderedText
            let clampedStart = min(hit.start, text.count)
            let startIndex = text.index(text.startIndex, offsetBy: clampedStart)
            let endIndex = text.index(startIndex, offsetBy: min(hit.length, text.count - clampedStart))
            return WebPaneHit(
                m: hit.messageIndex,
                s: text.utf16.distance(from: text.utf16.startIndex, to: startIndex),
                l: text.utf16.distance(from: startIndex, to: endIndex),
                hidden: ConversationHits.requiresExpansion(hit: hit, messageText: text)
            )
        }
    }

    /// JSON with stable key order — both for golden tests and so the bridge
    /// string is deterministic.
    public static func encodeJSON(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: Message/block translation

    private static func paneMessage(_ message: ConversationMessage, _ rendered: RenderedMessage) -> WebPaneMessage {
        let limit = ConversationsConstants.messageFoldCharacterLimit
        let folds = ConversationHits.isFolded(rendered.renderedText)
        let charLengths = rendered.blocks.map { $0.renderedText.count }
        let foldedCharLengths = ConversationsRendering.foldedVisibleLengths(
            blockLengths: charLengths, limit: limit
        )
        let blockStartChars = ConversationsRendering.blockStartOffsets(rendered.blocks)

        var blocks: [WebPaneBlock] = []
        var cursor = 0 // UTF-16 cumulative offset in the message's rendered text
        for (blockIndex, block) in rendered.blocks.enumerated() {
            let utf16Len = block.renderedText.utf16.count
            let foldedLen = foldedUTF16Length(
                block.renderedText, visibleCharacters: foldedCharLengths?[blockIndex]
            )
            blocks.append(paneBlock(
                block, start: cursor, foldedLen: foldedLen,
                messageFoldBudgetChars: foldedCharLengths == nil ? nil : limit,
                blockStartChars: blockStartChars[blockIndex]
            ))
            cursor += utf16Len + 1
        }
        return WebPaneMessage(
            seq: message.seq, role: message.role,
            len: max(0, cursor - 1), folds: folds, blocks: blocks
        )
    }

    private static func paneBlock(
        _ block: MessageBlock, start: Int, foldedLen: Int,
        messageFoldBudgetChars: Int?, blockStartChars: Int
    ) -> WebPaneBlock {
        switch block.kind {
        case .table(let rows):
            // Cell offsets mirror Core's TableCell.startOffset structure;
            // joins are one unit in both coordinate systems, so cumulative
            // UTF-16 sums land on the same boundaries.
            var paneRows: [[WebPaneCell]] = []
            var cursor = start
            var isFirst = true
            for row in rows {
                var paneRow: [WebPaneCell] = []
                for cell in row {
                    if !isFirst { cursor += 1 }
                    isFirst = false
                    let cellFolded: Int
                    if let budget = messageFoldBudgetChars {
                        // Core's visibleTableCellLengths rule (§4.6).
                        let visibleChars = max(0, min(
                            cell.renderedText.count,
                            budget - (blockStartChars + cell.startOffset)
                        ))
                        cellFolded = foldedUTF16Length(cell.renderedText, visibleCharacters: visibleChars)
                    } else {
                        cellFolded = cell.renderedText.utf16.count
                    }
                    paneRow.append(WebPaneCell(
                        text: cell.renderedText,
                        runs: runs(from: cell.text),
                        start: cursor,
                        foldedLen: cellFolded
                    ))
                    cursor += cell.renderedText.utf16.count
                }
                paneRows.append(paneRow)
            }
            return WebPaneBlock(
                kind: "table", level: nil, indent: nil, text: nil, runs: nil,
                start: start, foldedLen: foldedLen, rows: paneRows
            )
        case .userText:
            return textBlock("user", block, start: start, foldedLen: foldedLen)
        case .paragraph:
            return textBlock("p", block, start: start, foldedLen: foldedLen)
        case .heading(let level):
            return WebPaneBlock(
                kind: "h", level: level, indent: nil, text: block.renderedText,
                runs: runs(from: block.text), start: start, foldedLen: foldedLen, rows: nil
            )
        case .codeBlock:
            return WebPaneBlock(
                kind: "code", level: nil, indent: nil, text: block.renderedText,
                runs: nil, start: start, foldedLen: foldedLen, rows: nil
            )
        case .listItem(let indent):
            return WebPaneBlock(
                kind: "li", level: nil, indent: indent, text: block.renderedText,
                runs: runs(from: block.text), start: start, foldedLen: foldedLen, rows: nil
            )
        }
    }

    private static func textBlock(_ kind: String, _ block: MessageBlock, start: Int, foldedLen: Int) -> WebPaneBlock {
        WebPaneBlock(
            kind: kind, level: nil, indent: nil, text: block.renderedText,
            runs: runs(from: block.text), start: start, foldedLen: foldedLen, rows: nil
        )
    }

    /// UTF-16 length of the first `visibleCharacters` Characters.
    private static func foldedUTF16Length(_ text: String, visibleCharacters: Int?) -> Int {
        guard let visibleCharacters else { return text.utf16.count }
        if visibleCharacters >= text.count { return text.utf16.count }
        return String(text.prefix(visibleCharacters)).utf16.count
    }

    /// Inline style runs (UTF-16 offsets local to the block text), extracted
    /// from Foundation's markdown intents in one ordered pass. Link targets
    /// pass only as http/https (§4.6: links open in the default browser;
    /// javascript:/file:/anything else from a transcript never reaches the
    /// page as an href — the text still renders, unlinked).
    private static func runs(from attributed: AttributedString) -> [WebPaneRun]? {
        var result: [WebPaneRun] = []
        var cursor = 0
        for run in attributed.runs {
            let piece = String(attributed.characters[run.range])
            let length = piece.utf16.count
            defer { cursor += length }
            let intent = run.inlinePresentationIntent
            let href = run.link.flatMap { url -> String? in
                let scheme = url.scheme?.lowercased()
                return (scheme == "http" || scheme == "https") ? url.absoluteString : nil
            }
            let code = intent?.contains(.code) == true
            let bold = intent?.contains(.stronglyEmphasized) == true
            let italic = intent?.contains(.emphasized) == true
            let strike = intent?.contains(.strikethrough) == true
            guard code || bold || italic || strike || href != nil else { continue }
            result.append(WebPaneRun(
                s: cursor, l: length,
                code: code ? true : nil, bold: bold ? true : nil,
                italic: italic ? true : nil, strike: strike ? true : nil,
                href: href
            ))
        }
        return result.isEmpty ? nil : result
    }
}
