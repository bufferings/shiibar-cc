// Conversations window UI (DESIGN.md §4.6; visual spec:
// docs/conversations-design.html). Two-pane master/detail: left = search +
// list + status line, right = the selected conversation's full text (bottom
// = latest) + Resume. All decisions (query rules, hit offsets, folding,
// status text) live in `ConversationsViewModel` / ShiibarCcCore; this file is
// presentation only. UI strings are English; conversation content (titles,
// message text) is user data shown verbatim.

import ShiibarCcCore
import SwiftUI

struct ConversationsContentView: View {
    @ObservedObject var viewModel: ConversationsViewModel

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: ConversationsWindow.leftPaneWidth)
            Divider()
            rightPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
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
            ConversationPreview(viewModel: viewModel, detail: detail)
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

// MARK: - List row

/// One list row (conversations-design.html): line 1 = title (folder label
/// fallback when null), line 2 = folder label · elapsed, with a faint
/// `running` marker on line 2 for a live conversation (§4.6 — no status
/// glyphs, no color).
private struct ConversationRow: View {
    let summary: ConversationSummary
    let home: String?
    let isSelected: Bool

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
            Text(primaryLine)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            HStack(spacing: 4) {
                Text("\(folderLabel) · \(elapsed)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                if summary.live {
                    Text("· running")
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
                .fill(Color(nsColor: .selectedContentBackgroundColor))
                .opacity(isSelected ? 1 : 0)
        )
    }
}

// MARK: - Preview (right pane content)

private struct ConversationPreview: View {
    @ObservedObject var viewModel: ConversationsViewModel
    let detail: ConversationDetail

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
            Text(headerElapsed.map { "\(headerPath) · \($0) ago" } ?? headerPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var chat: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(detail.messages.enumerated()), id: \.element.seq) { index, message in
                    MessageView(
                        message: message,
                        messageIndex: index,
                        hits: viewModel.hits,
                        currentHitIndex: viewModel.currentHitIndex,
                        isExpanded: viewModel.expandedMessageSeqs.contains(message.seq),
                        onExpand: { viewModel.expandMessage(seq: message.seq) }
                    )
                    .id(message.seq)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        // §4.6: read from the bottom (latest) by default; hit jumps and
        // scroll memory drive `scrolledMessageID` (macOS 14 `scrollPosition`).
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $viewModel.scrolledMessageID)
    }
}

// MARK: - One message

private struct MessageView: View {
    let message: ConversationMessage
    let messageIndex: Int
    let hits: [ConversationHit]
    let currentHitIndex: Int?
    let isExpanded: Bool
    let onExpand: () -> Void

    private var isUser: Bool { message.role == "user" }
    private var roleLabel: String { isUser ? "You" : "Claude" }

    /// Whether this message is folded and not yet expanded.
    private var isFolded: Bool {
        ConversationHits.isFolded(message.text) && !isExpanded
    }

    /// The text actually shown (folded prefix while collapsed).
    private var visibleText: String {
        isFolded ? ConversationHits.foldedPrefix(message.text) : message.text
    }

    /// This message's hits, and which local one is the current position.
    private var localHits: [(hit: ConversationHit, isCurrent: Bool)] {
        hits.enumerated()
            .filter { $0.element.messageIndex == messageIndex }
            .map { (hit: $0.element, isCurrent: $0.offset == currentHitIndex) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(roleLabel)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(highlighted)
                .font(.system(size: 12))
                .foregroundStyle(isUser ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isFolded {
                Button("Show full message", action: onExpand)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The visible text with a background-color highlight on every visible
    /// hit (§4.6: background attribute only, never bold — bold would change
    /// wrapping and break the "scroll doesn't move" rule). The current
    /// position is a stronger color.
    private var highlighted: AttributedString {
        var attributed = AttributedString(visibleText)
        let characters = attributed.characters
        let count = characters.count
        for entry in localHits {
            let start = entry.hit.start
            let end = start + entry.hit.length
            // Skip hits outside the visible (folded) prefix.
            guard start >= 0, end <= count else { continue }
            guard let lower = characters.index(
                characters.startIndex, offsetBy: start, limitedBy: characters.endIndex
            ), let upper = characters.index(
                lower, offsetBy: entry.hit.length, limitedBy: characters.endIndex
            ) else { continue }
            let color: Color = entry.isCurrent
                ? Color(nsColor: .systemOrange).opacity(0.6)
                : Color(nsColor: .systemYellow).opacity(0.4)
            attributed[lower..<upper].backgroundColor = color
        }
        return attributed
    }
}
