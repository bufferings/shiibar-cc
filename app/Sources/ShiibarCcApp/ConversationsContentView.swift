// Conversations window UI (DESIGN.md §4.6; visual spec:
// docs/conversations-design.html). Two-pane master/detail with a full-height
// sidebar: left = search + list + status line on sidebar material that
// reaches the window top (the traffic lights sit over it), right = the
// selected conversation on the normal window background — the reading
// surface (§8.35). User messages are full-width bands (the "what did I ask"
// table of contents); Claude messages render their Markdown. All decisions
// (query rules, block splitting, hit offsets, fold boundary, tick math) live
// in `ConversationsViewModel` / ShiibarCcCore; this file is presentation
// only. UI strings are English; conversation content (titles, message text)
// is user data shown verbatim.

import AppKit
import ShiibarCcCore
import SwiftUI

struct ConversationsContentView: View {
    @ObservedObject var viewModel: ConversationsViewModel
    /// Shared body-size store (§4.6/§4.5): observed here so cmd shortcuts
    /// and the Settings stepper re-render the right pane immediately.
    @ObservedObject var textSize: ConversationsTextSizeStore

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: ConversationsWindow.leftPaneWidth)
                .background(
                    // Full-height sidebar (§4.6/§8.35): sidebar material up
                    // to the window top — `.ignoresSafeArea` extends it under
                    // the hidden-title-bar traffic-light band — with a 1pt
                    // separator against the reading pane.
                    SidebarBackgroundView()
                        .overlay(alignment: .trailing) {
                            Color(nsColor: .separatorColor).frame(width: 1)
                        }
                        .ignoresSafeArea()
                )
            rightPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            toolbar
            listArea
            Divider()
            Text(viewModel.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search (2+ characters)", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .disabled(viewModel.searchDisabled)
                    .onChange(of: viewModel.query) {
                        // List search is debounced (§9); preview highlights
                        // recompute instantly and never move the scroll.
                        viewModel.queryChanged()
                        viewModel.queryChangedForPreview()
                    }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Button {
                viewModel.refreshTapped()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .help("Refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var listArea: some View {
        if let message = viewModel.listEmptyMessage {
            VStack {
                Spacer()
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(viewModel.summaries) { summary in
                        ConversationRow(
                            summary: summary,
                            home: viewModel.home,
                            isSelected: summary.sessionID == viewModel.selectedSessionID
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.selectConversation(summary) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Right pane

    @ViewBuilder
    private var rightPane: some View {
        if let detail = viewModel.detail {
            ConversationPreview(viewModel: viewModel, detail: detail, bodySize: textSize.size)
        } else {
            VStack {
                Spacer()
                Text("Select a conversation")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The sidebar material (§4.6: NSVisualEffectView sidebar material, behind-
/// window blending, following the window's active state — the System
/// Settings look; colors come from the system, never hardcoded).
private struct SidebarBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - List row

/// One list row (§4.6 / conversations-design.html): line 1 = title (folder
/// label fallback when null) with the elapsed time right-aligned in the
/// secondary color, line 2 = folder label (+ a faint `· running` marker for
/// a live conversation — no status glyphs, no color). Rows get a hover
/// highlight (the dropdown's convention: rounded 7pt); no separators, no
/// group headers — the row's inner structure and hover do the separating.
private struct ConversationRow: View {
    let summary: ConversationSummary
    let home: String?
    let isSelected: Bool
    @State private var isHovering = false

    private var folderLabel: String {
        CwdLabel.format(cwd: summary.cwd ?? "", home: home)
    }

    private var primaryLine: String {
        if let title = summary.title, !title.isEmpty { return title }
        let label = folderLabel
        return label.isEmpty ? summary.sessionID : label
    }

    private var elapsed: String {
        ElapsedTime.format(seconds: Int64(Date().timeIntervalSince1970) - summary.updatedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(primaryLine)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(elapsed)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.78)) : AnyShapeStyle(.secondary))
            }
            HStack(spacing: 4) {
                Text(folderLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if summary.live {
                    Text("\u{00B7} running")
                        .opacity(0.85)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.78)) : AnyShapeStyle(.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(rowBackground)
        )
        .onHover { isHovering = $0 }
    }

    /// Selection wins over hover; hover is the neutral fill the mock's
    /// `--hov` swatch stands for (translucent gray adapts to both themes).
    private var rowBackground: Color {
        if isSelected { return Color(nsColor: .selectedContentBackgroundColor) }
        if isHovering { return Color.gray.opacity(0.13) }
        return Color.clear
    }
}

// MARK: - Preview (right pane content)

private struct ConversationPreview: View {
    @ObservedObject var viewModel: ConversationsViewModel
    let detail: ConversationDetail
    let bodySize: Double

    /// The selected list row (for cwd / elapsed / live / resume) — the
    /// preview's own detail carries no live flag or timestamp.
    private var summary: ConversationSummary? {
        viewModel.summaries.first { $0.sessionID == viewModel.selectedSessionID }
    }

    private var headerTitle: String {
        if let title = detail.title, !title.isEmpty { return title }
        let label = CwdLabel.format(cwd: detail.cwd ?? "", home: viewModel.home)
        return label.isEmpty ? detail.sessionID : label
    }

    private var headerPath: String {
        HomeRelativePath.format(detail.cwd ?? "", home: viewModel.home)
    }

    private var headerElapsed: String? {
        guard let summary else { return nil }
        return ElapsedTime.format(seconds: Int64(Date().timeIntervalSince1970) - summary.updatedAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !viewModel.hits.isEmpty {
                findBar
                Divider()
            }
            chat
            if let summary, viewModel.canResume(summary) {
                Divider()
                HStack {
                    Spacer()
                    Button("Resume") { viewModel.resume(summary) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headerTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(headerElapsed.map { "\(headerPath) \u{00B7} \($0) ago" } ?? headerPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Text("\((viewModel.currentHitIndex ?? 0) + 1)/\(viewModel.hits.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                viewModel.navigateToOlderHit()
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            Button {
                viewModel.navigateToNewerHit()
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var chat: some View {
        ScrollView {
            // No horizontal padding on the stack: user bands span the full
            // pane width (§4.6); Claude blocks carry their own insets.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(detail.messages.enumerated()), id: \.element.seq) { index, message in
                    MessageView(
                        message: message,
                        rendered: viewModel.renderedMessages.indices.contains(index)
                            ? viewModel.renderedMessages[index]
                            : RenderedMessage(role: message.role, text: message.text),
                        messageIndex: index,
                        isFirst: index == 0,
                        hits: viewModel.hits,
                        currentHitIndex: viewModel.currentHitIndex,
                        isExpanded: viewModel.expandedMessageSeqs.contains(message.seq),
                        bodySize: bodySize,
                        onExpand: { viewModel.expandMessage(seq: message.seq) },
                        onCollapse: { viewModel.collapseMessage(seq: message.seq) }
                    )
                    .id(message.seq)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        // §4.6: read from the bottom (latest) by default; hit jumps and
        // scroll memory drive `scrolledMessageID` (macOS 14 `scrollPosition`).
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $viewModel.scrolledMessageID)
        // §4.6: hit distribution tick marks near the right edge while the
        // find bar is visible (message-level approximation; overlay, not the
        // scroller itself).
        .overlay {
            if !viewModel.hits.isEmpty {
                HitTicksOverlay(
                    fractions: viewModel.tickFractions,
                    currentIndex: viewModel.currentHitIndex
                )
            }
        }
    }
}

/// The §4.6 hit tick marks: one small bar per hit at its approximate
/// vertical position over the chat viewport, the current hit in the stronger
/// color (same hue family as the highlights). Purely decorative — never
/// intercepts clicks or scrolling.
private struct HitTicksOverlay: View {
    let fractions: [Double]
    let currentIndex: Int?

    var body: some View {
        GeometryReader { geometry in
            ForEach(fractions.indices, id: \.self) { index in
                Capsule()
                    .fill(index == currentIndex
                        ? ConversationHighlight.currentColor
                        : ConversationHighlight.baseColor)
                    .frame(width: 8, height: 3)
                    .position(
                        x: geometry.size.width - 5,
                        y: min(max(fractions[index] * geometry.size.height, 4), max(geometry.size.height - 4, 4))
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

/// The reading pane's two-column grid (§4.6 / conversations-design.html:
/// a 16px inset, a 12.5px centered glyph column, and a 9px gap at the 13px
/// default body size). The band's "\u{276F}" and every Claude message's
/// "\u{23FA}" reply marker sit in the SAME glyph column, and the band text
/// starts at the same x as the body text — both sections use these exact
/// values, so the alignment holds at every ⌘± text size (the column is a
/// fixed frame, not glyph metrics, so the band's +0.5pt font can't skew it).
/// The glyph column scales with the body size (12.5/13 of an em, like the
/// reference CSS); inset and gap stay fixed.
private enum MessageGrid {
    static let leadingInset: CGFloat = 16
    static let trailingInset: CGFloat = 18
    static let glyphGap: CGFloat = 9

    static func glyphColumnWidth(bodySize: Double) -> CGFloat {
        CGFloat(bodySize) * 12.5 / 13
    }

    /// Where the body/band text column starts, from the pane's left edge.
    static func bodyColumnInset(bodySize: Double) -> CGFloat {
        leadingInset + glyphColumnWidth(bodySize: bodySize) + glyphGap
    }
}

/// The two highlight colors (§4.6: background-color only, never bold; the
/// current position is the stronger one). Shared by in-text highlights, the
/// hidden-hit badge, and the tick marks so they read as one system.
private enum ConversationHighlight {
    static let baseColor = Color(nsColor: .systemYellow).opacity(0.4)
    static let currentColor = Color(nsColor: .systemOrange).opacity(0.6)
}

// MARK: - One message

/// One message under the §4.6 rendering grammar: a user message is a
/// full-width band (monospaced semibold "\u{276F}" glyph + the words verbatim at
/// body +0.5pt, regular weight — the band is the heading, so the text is
/// not); a Claude message is its Markdown blocks. No role label lines. Long
/// messages fold at the §9 boundary (counted on rendered text, cut on the
/// block sequence); "Show full message" carries a hidden-hit badge, expanded
/// messages end with "Show less".
private struct MessageView: View {
    let message: ConversationMessage
    let rendered: RenderedMessage
    let messageIndex: Int
    let isFirst: Bool
    let hits: [ConversationHit]
    let currentHitIndex: Int?
    let isExpanded: Bool
    let bodySize: Double
    let onExpand: () -> Void
    let onCollapse: () -> Void

    private var isUser: Bool { message.role == "user" }

    /// Whether the rendered text exceeds the fold boundary at all.
    private var exceedsFold: Bool {
        ConversationHits.isFolded(rendered.renderedText)
    }

    private var isFolded: Bool { exceedsFold && !isExpanded }

    /// Per-block visible character counts while folded, nil when everything
    /// is visible.
    private var foldedVisibleLengths: [Int]? {
        guard isFolded else { return nil }
        return ConversationsRendering.foldedVisibleLengths(
            blockLengths: rendered.blocks.map { $0.renderedText.count },
            limit: ConversationsConstants.messageFoldCharacterLimit
        )
    }

    /// Hits hidden behind the fold (badge count, §4.6).
    private var hiddenHitCount: Int {
        guard isFolded else { return 0 }
        return ConversationHits.hiddenHitCount(
            hits: hits,
            messageIndex: messageIndex,
            visibleLimit: ConversationsConstants.messageFoldCharacterLimit
        )
    }

    /// The reading measure (§4.6): body lines cap at about 60em so a wide
    /// window doesn't stretch them.
    private var readingMeasure: CGFloat { CGFloat(bodySize) * 60 }

    var body: some View {
        Group {
            if isUser {
                userSection
            } else {
                assistantSection
            }
        }
        // A band gets generous space before it (a section break, §4.6);
        // plain body flows tighter. The first message starts flush.
        .padding(.top, isFirst ? 0 : (isUser ? 22 : 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: User band

    private var userSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: MessageGrid.glyphGap) {
                Text("\u{276F}")
                    .font(.system(size: bodySize + 0.5, weight: .semibold, design: .monospaced))
                    .frame(width: MessageGrid.glyphColumnWidth(bodySize: bodySize))
                Text(displayText(blockIndex: 0))
                    .font(.system(size: bodySize + 0.5))
                    .lineSpacing(bodySize * 0.3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.init(
                top: 7, leading: MessageGrid.leadingInset, bottom: 7, trailing: MessageGrid.trailingInset
            ))
            .background(Color.gray.opacity(0.1))
            foldControl
                .padding(.leading, MessageGrid.bodyColumnInset(bodySize: bodySize))
        }
    }

    // MARK: Claude blocks

    private var assistantSection: some View {
        // §4.6: every Claude message starts with a small faint reply marker
        // hanging to the LEFT of its body — same glyph column as the band's
        // "\u{276F}" — so consecutive replies to one prompt stay
        // distinguishable. Unconditional (no "only when consecutive"
        // branching), no state meaning, no color coding. The marker is a
        // separate view, never part of the rendered text (hit computation
        // and the fold boundary don't see it). Top alignment (not
        // firstTextBaseline): the first block can be a code block, whose
        // baseline would drag the marker to its bottom; a line-height frame
        // centers the dot on the first text line instead.
        HStack(alignment: .top, spacing: MessageGrid.glyphGap) {
            Text("\u{23FA}")
                .font(.system(size: bodySize * 0.7))
                .foregroundStyle(.secondary)
                .frame(
                    width: MessageGrid.glyphColumnWidth(bodySize: bodySize),
                    height: bodySize * 1.25
                )
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(rendered.blocks.enumerated()), id: \.offset) { index, block in
                    if visibleLength(blockIndex: index) > 0 {
                        blockView(block, blockIndex: index)
                    }
                }
                foldControl
            }
            .frame(maxWidth: readingMeasure, alignment: .leading)
        }
        .padding(.leading, MessageGrid.leadingInset)
        .padding(.trailing, MessageGrid.trailingInset)
    }

    @ViewBuilder
    private func blockView(_ block: MessageBlock, blockIndex: Int) -> some View {
        switch block.kind {
        case .userText, .paragraph:
            Text(displayText(blockIndex: blockIndex))
                .font(.system(size: bodySize))
                .lineSpacing(bodySize * 0.35)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            Text(displayText(blockIndex: blockIndex))
                .font(.system(size: headingSize(level), weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        case .listItem(let indent):
            Text(displayText(blockIndex: blockIndex))
                .font(.system(size: bodySize))
                .lineSpacing(bodySize * 0.35)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, CGFloat(indent) * 14)
        case .codeBlock:
            // §4.6: monospace + subtle background + horizontal scroll, body
            // -1.5pt (§9), inside the reading measure.
            ScrollView(.horizontal) {
                Text(displayText(blockIndex: blockIndex))
                    .font(.system(size: bodySize + ConversationsTextSize.codeDelta, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .table(let rows):
            tableView(rows: rows, blockIndex: blockIndex)
        }
    }

    // MARK: Pipe table (§4.6/§8.37)

    /// A pipe table as a native grid: header row semibold on a subtle
    /// background, hairline separators between rows, all columns
    /// left-aligned (alignment hints are ignored), rounded hairline border.
    /// The table keeps its CONTENT width (never stretched to the reading
    /// measure); a wide table scrolls horizontally inside itself — the code
    /// block grammar (§4.6). `ViewThatFits` picks the plain content-width
    /// grid when it fits the measure and the in-table scroller otherwise.
    @ViewBuilder
    private func tableView(rows: [[TableCell]], blockIndex: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            tableChrome(tableGrid(rows: rows, blockIndex: blockIndex))
            tableChrome(ScrollView(.horizontal) { tableGrid(rows: rows, blockIndex: blockIndex) })
        }
    }

    /// Rounded hairline border + matching clip, shared by the fitting and
    /// the scrolling variants (the html .tbl reference chrome).
    private func tableChrome(_ content: some View) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
    }

    private func tableGrid(rows: [[TableCell]], blockIndex: Int) -> some View {
        // Fold intersection (§4.6): when the fold cut lands mid-table, show
        // only the cells within the rendered-text budget — the straddling
        // cell shows its prefix, cells past the cut disappear (hidden cells
        // are always a suffix of the table, so no grid column is skipped
        // mid-row). When not folded, everything is visible, including
        // genuinely empty cells, which keep their grid slot.
        let isFoldedCut = foldedVisibleLengths != nil
        let budget = visibleLength(blockIndex: blockIndex)
        let blockStart = rendered.blockStartOffsets.indices.contains(blockIndex)
            ? rendered.blockStartOffsets[blockIndex]
            : 0
        return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                let row = rows[rowIndex]
                if !isFoldedCut || row.contains(where: { cellIsWithinBudget($0, budget: budget) }) {
                    GridRow {
                        ForEach(row.indices, id: \.self) { columnIndex in
                            let cell = row[columnIndex]
                            if !isFoldedCut || cellIsWithinBudget(cell, budget: budget) {
                                tableCellView(
                                    cell,
                                    isHeader: rowIndex == 0,
                                    visibleCount: isFoldedCut
                                        ? max(0, min(cell.renderedText.count, budget - cell.startOffset))
                                        : cell.renderedText.count,
                                    blockStart: blockStart
                                )
                            }
                        }
                    }
                }
            }
        }
        // Ideal (content) width in both ViewThatFits variants: never
        // stretched to the measure, and inside the horizontal scroller the
        // infinite proposal must not inflate the flexible cells.
        .fixedSize(horizontal: true, vertical: false)
    }

    /// While folded, a cell stays on screen exactly while the cut has not
    /// passed its start: a straddling cell shows its prefix, an empty cell
    /// inside the visible part keeps its slot, cells past the cut disappear.
    private func cellIsWithinBudget(_ cell: TableCell, budget: Int) -> Bool {
        cell.startOffset < budget
    }

    private func tableCellView(
        _ cell: TableCell, isHeader: Bool, visibleCount: Int, blockStart: Int
    ) -> some View {
        Text(highlightedFragment(
            cell.text,
            visibleCount: visibleCount,
            startOffsetInMessage: blockStart + cell.startOffset,
            baseSize: bodySize
        ))
        .font(.system(size: bodySize, weight: isHeader ? .semibold : .regular))
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(isHeader ? Color.gray.opacity(0.1) : Color.clear)
        .overlay(alignment: .top) {
            // CSS reference: a hairline above every data row (none above the
            // header). Per-cell overlays tile into a continuous rule because
            // the cells fill their columns with zero spacing.
            if !isHeader {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
            }
        }
    }

    /// Heading sizes step down from level 1 to 6, relative to the body.
    private func headingSize(_ level: Int) -> Double {
        switch level {
        case 1: return bodySize + 6
        case 2: return bodySize + 4
        case 3: return bodySize + 2
        default: return bodySize + 1
        }
    }

    // MARK: Fold controls (§4.6)

    @ViewBuilder
    private var foldControl: some View {
        if isFolded {
            HStack(spacing: 6) {
                Button("Show full message", action: onExpand)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                if let badge = ConversationHits.matchBadgeText(count: hiddenHitCount) {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(ConversationHighlight.baseColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        } else if exceedsFold {
            Button("Show less", action: onCollapse)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: Text assembly

    /// Number of this block's rendered characters currently visible.
    private func visibleLength(blockIndex: Int) -> Int {
        guard rendered.blocks.indices.contains(blockIndex) else { return 0 }
        if let visible = foldedVisibleLengths, visible.indices.contains(blockIndex) {
            return visible[blockIndex]
        }
        return rendered.blocks[blockIndex].renderedText.count
    }

    /// One block's display text — `highlightedFragment` at block granularity
    /// (table cells call it per cell instead).
    private func displayText(blockIndex: Int) -> AttributedString {
        guard rendered.blocks.indices.contains(blockIndex) else { return AttributedString() }
        let block = rendered.blocks[blockIndex]
        return highlightedFragment(
            block.text,
            visibleCount: visibleLength(blockIndex: blockIndex),
            startOffsetInMessage: rendered.blockStartOffsets.indices.contains(blockIndex)
                ? rendered.blockStartOffsets[blockIndex]
                : 0,
            baseSize: baseSize(for: block.kind)
        )
    }

    /// One displayed fragment (a block, or one table cell): the (possibly
    /// fold-truncated) content with inline intents mapped to concrete
    /// styles, then a background-color highlight on every fully visible hit
    /// (§4.6: background attribute only, never bold — bold would change
    /// wrapping and break the "scroll doesn't move" rule; highlights come
    /// LAST so they win over the inline-code background). The current
    /// position gets the stronger color. Hit offsets are in the message's
    /// joined rendered text; `startOffsetInMessage` maps them into this
    /// fragment. A hit can't span fragments (terms contain no whitespace,
    /// every join character is "\n").
    private func highlightedFragment(
        _ source: AttributedString,
        visibleCount: Int,
        startOffsetInMessage: Int,
        baseSize: Double
    ) -> AttributedString {
        var attributed = source
        let fullCount = attributed.characters.count
        if visibleCount < fullCount {
            let characters = attributed.characters
            if let end = characters.index(
                characters.startIndex, offsetBy: max(0, visibleCount), limitedBy: characters.endIndex
            ) {
                attributed = AttributedString(attributed[attributed.startIndex..<end])
            }
        }
        attributed = styledInline(attributed, baseSize: baseSize)

        for (globalIndex, hit) in hits.enumerated() where hit.messageIndex == messageIndex {
            let localStart = hit.start - startOffsetInMessage
            let localEnd = localStart + hit.length
            // Only hits fully inside this fragment's visible part; a hit
            // straddling the fold stays un-highlighted (it is counted in the
            // hidden-hit badge instead).
            guard localStart >= 0, localEnd <= visibleCount else { continue }
            let characters = attributed.characters
            guard let lower = characters.index(
                characters.startIndex, offsetBy: localStart, limitedBy: characters.endIndex
            ), let upper = characters.index(
                lower, offsetBy: hit.length, limitedBy: characters.endIndex
            ) else { continue }
            attributed[lower..<upper].backgroundColor = globalIndex == currentHitIndex
                ? ConversationHighlight.currentColor
                : ConversationHighlight.baseColor
        }
        return attributed
    }

    /// Map Foundation's inline presentation intents (from the markdown
    /// parse) to concrete SwiftUI attributes at the current body size:
    /// bold/italic via font, inline code as monospaced with a subtle
    /// background, strikethrough as a line style. Links keep the `.link`
    /// attribute (SwiftUI styles and opens them); style is all §4.6 asks.
    /// The intent attribute itself is cleared afterwards so the mapping here
    /// is the single source of the styling. Spans are collected as character
    /// offsets first and applied after — mutating attributes invalidates the
    /// indices of the runs being walked.
    /// The base font size of a block's plain runs — inline spans style
    /// relative to it so e.g. a code span inside a heading keeps the
    /// heading's size.
    private func baseSize(for kind: MessageBlock.Kind) -> Double {
        switch kind {
        case .userText: return bodySize + 0.5
        case .heading(let level): return headingSize(level)
        case .codeBlock: return bodySize + ConversationsTextSize.codeDelta
        case .paragraph, .listItem, .table: return bodySize
        }
    }

    private func styledInline(_ source: AttributedString, baseSize: Double) -> AttributedString {
        var spans: [(start: Int, length: Int, intent: InlinePresentationIntent)] = []
        let sourceCharacters = source.characters
        for run in source.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            spans.append((
                start: sourceCharacters.distance(from: sourceCharacters.startIndex, to: run.range.lowerBound),
                length: sourceCharacters.distance(from: run.range.lowerBound, to: run.range.upperBound),
                intent: intent
            ))
        }
        guard !spans.isEmpty else { return source }

        var result = source
        for span in spans {
            let characters = result.characters
            guard let lower = characters.index(
                characters.startIndex, offsetBy: span.start, limitedBy: characters.endIndex
            ), let upper = characters.index(
                lower, offsetBy: span.length, limitedBy: characters.endIndex
            ) else { continue }
            if span.intent.contains(.code) {
                result[lower..<upper].font = .system(size: baseSize, design: .monospaced)
                result[lower..<upper].backgroundColor = Color.gray.opacity(0.12)
            } else if span.intent.contains(.stronglyEmphasized) || span.intent.contains(.emphasized) {
                var font: Font = .system(size: baseSize)
                if span.intent.contains(.stronglyEmphasized) { font = font.weight(.semibold) }
                if span.intent.contains(.emphasized) { font = font.italic() }
                result[lower..<upper].font = font
            }
            if span.intent.contains(.strikethrough) {
                result[lower..<upper].strikethroughStyle = .single
            }
            result[lower..<upper].inlinePresentationIntent = nil
        }
        return result
    }
}
