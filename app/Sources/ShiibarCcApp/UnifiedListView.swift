// The list page (DESIGN.md §4.5 "header row" / "the list has two sections"
// / "Running rows" / "the row's `>` button" / "row selection" / "row click"
// / "fixed footer" / "key hints", §4.6 "History section" / "stars" /
// "bottom panel"; visual spec: docs/window-design.html "list page", "row
// parts", "fixed footer"). Presentation only: every text, state and enabled
// flag comes from `MainSurfaceModel.list` (Core).

import AppKit
import ShiibarCcCore
import SwiftUI

/// Header row + list + footer. One column: the footer is the warning rows,
/// the message line and the bottom panel (key hints + the selected row's
/// buttons — §4.6 "bottom panel"). Two columns (the left column): the fixed
/// footer with the key hints only (§4.5 "fixed footer").
struct ListPageView: View {
    @ObservedObject var model: MainSurfaceModel
    let surface: MainSurface

    var body: some View {
        VStack(spacing: 0) {
            HeaderRowView(model: model, surface: surface)
            ListBodyView(model: model, surface: surface)
            if let panel = model.list.listBottomPanel {
                PanelStatusLinesView(model: model)
                BottomPanelView(model: model, panel: panel)
            } else {
                FixedFooterView(model: model, hints: model.list.footerHints)
            }
        }
    }
}

// MARK: - Header row

/// Search field / ⟳ / `Open in window` (popover) or the pin (window) / ⌄.
struct HeaderRowView: View {
    @ObservedObject var model: MainSurfaceModel
    let surface: MainSurface
    @State private var menuAnchor: NSView?

    var body: some View {
        HStack(spacing: 8) {
            if surface == .window {
                // The traffic lights sit here (hidden title bar, §4.5).
                Color.clear.frame(width: SurfaceMetrics.trafficLightsWidth - 8, height: 1)
            }
            ConversationsSearchField(
                text: $model.query,
                isEnabled: !model.list.isFullBuild,
                focusToken: model.searchFocusRequests[surface] ?? 0
            )
            // window-design.html `.search`: 24pt tall, level with the 24pt
            // header buttons.
            .frame(height: SurfaceMetrics.searchFieldHeight)
            // window-design.html `.search.dis`: faded while a full index
            // build disables the field (§4.6).
            .opacity(model.list.isFullBuild ? 0.5 : 1)
            RefreshButton(startTime: model.refreshStartedAt, runEndTime: model.refreshRunEndedAt) {
                model.refreshClicked()
            }
            switch surface {
            case .popover:
                Button { model.openInWindowClicked() } label: {
                    SurfaceIconView(icon: .window)
                        .frame(width: SurfaceMetrics.headerButton, height: SurfaceMetrics.headerButton)
                }
                .buttonStyle(HoverChipButtonStyle())
                .foregroundStyle(SurfaceColors.secondary)
                .help("Open in window")
            case .window:
                Button { model.keepOnTopClicked() } label: {
                    SurfaceIconView(icon: .pin, filled: model.keepOnTop)
                        .frame(width: SurfaceMetrics.headerButton, height: SurfaceMetrics.headerButton)
                }
                .buttonStyle(HoverChipButtonStyle())
                .foregroundStyle(model.keepOnTop ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(SurfaceColors.secondary))
                .help("Keep on top")
            }
            Button {
                if let menuAnchor { model.menuClicked(anchor: menuAnchor, surface: surface) }
            } label: {
                SurfaceIconView(icon: .chevronDown, lineWidth: 1.6)
                    .frame(width: SurfaceMetrics.headerButton, height: SurfaceMetrics.headerButton)
            }
            .buttonStyle(HoverChipButtonStyle(restingOpacity: 0.10))
            .foregroundStyle(SurfaceColors.secondary)
            .background(MenuAnchorView { menuAnchor = $0 })
        }
        .padding(.horizontal, SurfaceMetrics.headerSide)
        .padding(.top, surface == .window
                 ? SurfaceMetrics.windowTrafficLightCenter - SurfaceMetrics.searchFieldHeight / 2
                 : SurfaceMetrics.headerTop)
        .padding(.bottom, SurfaceMetrics.headerBottom)
        .background(surface == .window ? WindowDragArea() : nil)
    }
}

/// ⟳ (§4.6 / §8.42 / §8.44): no ground at rest, hover raises a gray ground,
/// press sinks it; in flight the single arrow glyph rotates from upright and
/// settles at a whole turn, and the button is disabled.
struct RefreshButton: View {
    let startTime: Date?
    let runEndTime: Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let startTime {
                    TimelineView(.animation) { context in
                        let elapsed = context.date.timeIntervalSince(startTime)
                        let runEnd = runEndTime.map { $0.timeIntervalSince(startTime) }
                        let angle = ConversationsRefreshSpin.isSpinning(
                            elapsedSeconds: elapsed, runEndSeconds: runEnd
                        ) ? ConversationsRefreshSpin.angleDegrees(elapsedSeconds: elapsed) : 0
                        SurfaceIconView(icon: .refresh, lineWidth: 1.5)
                            .rotationEffect(.degrees(angle))
                    }
                } else {
                    SurfaceIconView(icon: .refresh, lineWidth: 1.5)
                }
            }
            .frame(width: SurfaceMetrics.headerButton, height: SurfaceMetrics.headerButton)
        }
        .buttonStyle(HoverChipButtonStyle(isEnabled: startTime == nil))
        .foregroundStyle(SurfaceColors.secondary)
        .disabled(startTime != nil)
        .help("Refresh")
    }
}

// MARK: - List

struct ListBodyView: View {
    @ObservedObject var model: MainSurfaceModel
    let surface: MainSurface
    @StateObject private var scroller = ListScroller()

    var body: some View {
        let list = model.list
        ScrollView {
            // An eager stack: every row has a real frame, so revealing or
            // restoring any row is exact (History is capped — §9 — so the
            // row count stays small).
            VStack(alignment: .leading, spacing: 0) {
                if let empty = list.emptyStateText {
                    Text(empty)
                        .font(.system(size: 12))
                        .foregroundStyle(SurfaceColors.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                }
                ForEach(list.sections) { section in
                    SectionHeaderView(section: section)
                    ForEach(section.rows) { row in
                        RowCardView(
                            row: row,
                            isSelected: list.selection?.key == row.id,
                            isSelectionActive: list.isSelectionActive,
                            showsOpenButton: list.showsRowOpenButton,
                            spinning: model.isSpinnerActive,
                            model: model
                        )
                        .padding(.bottom, 6)
                        .background(ListRowFrameReporter(key: row.id))
                    }
                }
                if let hidden = list.hiddenHistoryText {
                    // §4.6 / window-design.html: the count of rows the
                    // History cap hides — one centered line, not a card,
                    // not selectable.
                    Text(hidden)
                        .font(.system(size: 12))
                        .foregroundStyle(SurfaceColors.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .background(ListScrollProbe(scroller: scroller))
            .coordinateSpace(name: ListScroller.contentSpace)
            .onPreferenceChange(ListRowFramesKey.self) { rows in
                MainActor.assumeIsolated { scroller.rowsChanged(rows) }
            }
        }
        .onAppear {
            scroller.attach(model: model, surface: surface)
            if model.visibleSurface == surface { scroller.requestRestore() }
        }
        .onChange(of: model.visibleSurface) { _, visible in
            if visible == surface { scroller.requestRestore() }
        }
        .onChange(of: model.scrollSelectionRequest) {
            scroller.requestReveal()
        }
    }
}

/// Each row's frame in the list content (feeds `ListScroller`).
private struct ListRowFramesKey: PreferenceKey {
    static let defaultValue: [ListRowExtent] = []
    static func reduce(value: inout [ListRowExtent], nextValue: () -> [ListRowExtent]) {
        value.append(contentsOf: nextValue())
    }
}

private struct ListRowFrameReporter: View {
    let key: UnifiedRowKey

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named(ListScroller.contentSpace))
            Color.clear.preference(
                key: ListRowFramesKey.self,
                value: [ListRowExtent(key: key, top: Double(frame.minY), bottom: Double(frame.maxY))]
            )
        }
    }
}

/// Executes the list's scroll requests on the backing `NSScrollView`
/// (decisions: `ListReveal` / `ListScrollAnchor` in Core). The clip view is
/// moved directly, from the rows' measured frames: the offset is exact and
/// immediate, and no second scroll mechanism (a two-way scroll-position
/// binding) can move the list behind it. Not observed by any view, so
/// scrolling never re-renders the list.
@MainActor
final class ListScroller: ObservableObject {
    static let contentSpace = "shiibar.list.content"

    private weak var scrollView: NSScrollView?
    private weak var model: MainSurfaceModel?
    private var surface: MainSurface?
    private var rows: [ListRowExtent] = []
    private var boundsObserver: NSObjectProtocol?
    /// A restore waits until the scroll view and the row frames exist; until
    /// then the scroll is not recorded (the initial top would overwrite the
    /// shared position).
    private var pendingRestore = false
    private var pendingReveal = false

    func attach(model: MainSurfaceModel, surface: MainSurface) {
        self.model = model
        self.surface = surface
    }

    func scrollViewChanged(_ scrollView: NSScrollView?) {
        guard scrollView !== self.scrollView else { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        self.scrollView = scrollView
        guard let clip = scrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordAnchor() }
        }
        flushSoon()
    }

    func rowsChanged(_ rows: [ListRowExtent]) {
        self.rows = rows
        flushSoon()
    }

    /// The surface was shown: take the shared scroll position.
    func requestRestore() {
        pendingRestore = true
        flushSoon()
    }

    /// Reveal the selected row by the minimum scroll (§4.5).
    func requestReveal() {
        pendingReveal = true
        flushSoon()
    }

    /// Runs after the current SwiftUI update, so the row frames reflect it.
    private func flushSoon() {
        guard pendingRestore || pendingReveal else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        guard let scrollView, let model, !rows.isEmpty || model.list.sections.isEmpty else { return }
        if pendingRestore {
            pendingRestore = false
            if let anchor = model.listScrollAnchor,
               let viewport = viewport(), let top = anchor.restoredTop(viewport: viewport, rows: rows) {
                setTop(top, in: scrollView)
            }
        }
        if pendingReveal {
            guard let key = model.list.selection?.key else {
                pendingReveal = false
                return
            }
            // The selected row may not be laid out yet; the next row-frame
            // update retries.
            guard let row = rows.first(where: { $0.key == key }), let viewport = viewport() else { return }
            pendingReveal = false
            if let top = ListReveal.revealTop(viewport: viewport, row: row, isFirstRow: row.key == rows.first?.key) {
                setTop(top, in: scrollView)
            }
        }
    }

    /// The unobscured part of the list (the clip view's content insets
    /// excluded — `ListViewport`).
    private func viewport() -> ListViewport? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        return ListViewport(
            clipTop: Double(clip.bounds.minY), clipHeight: Double(clip.bounds.height),
            topInset: Double(clip.contentInsets.top), bottomInset: Double(clip.contentInsets.bottom),
            contentHeight: Double(document.frame.height)
        )
    }

    /// `top` is an unobscured top offset (see `viewport()`).
    private func setTop(_ top: Double, in scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let y = ListViewport.clipTop(forTop: top, topInset: Double(clip.contentInsets.top))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: CGFloat(y)))
        scrollView.reflectScrolledClipView(clip)
        recordAnchor()
    }

    /// Keep the shared scroll position (§4.5) — only the surface on screen
    /// writes it.
    private func recordAnchor() {
        guard !pendingRestore, let model, let surface, model.visibleSurface == surface,
              let viewport = viewport() else { return }
        if let anchor = ListScrollAnchor.capture(viewport: viewport, rows: rows) {
            model.listScrollAnchor = anchor
        }
    }
}

/// Hands the `NSScrollView` behind the SwiftUI `ScrollView` to the scroller.
private struct ListScrollProbe: NSViewRepresentable {
    let scroller: ListScroller

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.scroller = scroller
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.scroller = scroller
    }

    final class ProbeView: NSView {
        weak var scroller: ListScroller?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scroller?.scrollViewChanged(window == nil ? nil : enclosingScrollView)
        }
    }
}

/// Bold section name + row count (§4.5).
struct SectionHeaderView: View {
    let section: UnifiedListSectionModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.title)
                .font(.system(size: 12, weight: .bold))
            Text("\(section.count)")
                .font(.system(size: 11))
                .foregroundStyle(SurfaceColors.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// One card (§4.5 / §4.6): leading slot, three lines, and in one column the
/// `>` button at the right end. A click elsewhere on the card selects it;
/// whether the click is part of a double-click (Jump / Resume) is decided in
/// Core from the press the mouse-down monitor reported (§4.5).
struct RowCardView: View {
    let row: UnifiedListRow
    let isSelected: Bool
    /// The surface is key and the list has focus: the selected card is
    /// accent; otherwise gray (§4.5 "row selection").
    let isSelectionActive: Bool
    let showsOpenButton: Bool
    let spinning: Bool
    let model: MainSurfaceModel
    @State private var hovering = false

    private var selectionGround: Color {
        guard isSelected else { return .clear }
        return isSelectionActive ? SurfaceColors.selectionTint : SurfaceColors.inactiveSelectionTint
    }

    /// A selected card keeps its selection border on hover.
    private var border: Color {
        if isSelected {
            return isSelectionActive ? SurfaceColors.tintLine : SurfaceColors.inactiveSelectionLine
        }
        return hovering ? SurfaceColors.tintLine : SurfaceColors.cardBorder
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            leadingSlot
                .frame(width: 20, height: 20)
                .padding(.top, 1)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.line1)
                    .font(.system(size: 13, weight: row.isLine1Bold ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.line2)
                    .font(.system(size: 11))
                    .foregroundStyle(SurfaceColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                promptLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsOpenButton {
                RowOpenButton { model.rowOpenClicked(row.id) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(SurfaceColors.card)
                .overlay(RoundedRectangle(cornerRadius: 10).fill(selectionGround))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture { model.rowClicked(row.id) }
    }

    private var promptLine: some View {
        HStack(spacing: 5) {
            if let prompt = row.lastPrompt {
                Text(UnifiedListRow.promptMarker)
                    .font(.system(size: 11, design: .monospaced))
                    .opacity(0.8)
                Text(prompt)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // Keep the row height equal (§4.5 / §4.6).
                Text(" ")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(SurfaceColors.secondary)
    }

    @ViewBuilder
    private var leadingSlot: some View {
        switch row.leading {
        case .status(let kind, let unreviewed):
            RowSymbolView(kind: kind, unreviewed: unreviewed, spinning: spinning && kind == .working)
        case .star(let isStarred):
            // §4.6: the slot click toggles the star and never selects.
            Button { model.starClicked(sessionID: row.sessionID) } label: {
                StarView(isStarred: isStarred)
                    .opacity(isStarred || hovering ? 1 : 0)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.leading.tooltip ?? "")
        }
    }
}

/// The History star (window-design.html: 16px; outline in the secondary
/// color on hover, yellow fill when starred).
struct StarView: View {
    let isStarred: Bool

    var body: some View {
        ZStack {
            if isStarred {
                IconShape(icon: .star).fill(SurfaceColors.starFill)
                IconShape(icon: .star).stroke(SurfaceColors.starLine, style: StrokeStyle(lineWidth: 0.7, lineJoin: .round))
            } else {
                IconShape(icon: .star).stroke(SurfaceColors.secondary, style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// The row's `>` button (§4.5; window-design.html `.ib`: 28×26, radius 6,
/// a 15pt chevron in the secondary color; gray ground on hover / press).
/// Selects the row and opens the detail page.
struct RowOpenButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SurfaceIconView(icon: .chevronRight)
                .frame(width: SurfaceMetrics.rowOpenButtonWidth, height: SurfaceMetrics.rowOpenButtonHeight)
        }
        .buttonStyle(HoverChipButtonStyle(cornerRadius: 6))
        .foregroundStyle(SurfaceColors.secondary)
        .help(UnifiedListRow.openTooltip)
    }
}

// MARK: - Fixed footer

/// Warning rows, the message line, and the key hints (§4.5 "fixed footer"):
/// the two-column left column's footer.
struct FixedFooterView: View {
    @ObservedObject var model: MainSurfaceModel
    let hints: [KeyHint]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(SurfaceColors.line).frame(height: 1)
            StatusLinesView(model: model)
            if !hints.isEmpty {
                KeyHintsView(hints: hints)
                    .padding(.horizontal, 12)
                    .padding(.top, 7)
                    .padding(.bottom, 9)
            }
        }
    }
}

/// The warning rows and the message line (shared by the fixed footer and
/// the one-column pages' bottom panels — §4.5).
struct StatusLinesView: View {
    @ObservedObject var model: MainSurfaceModel

    var body: some View {
        ForEach(model.warnings, id: \.self) { warning in
            HStack(spacing: 7) {
                Text("\u{26A0}")
                Text(warning.text).lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(SurfaceColors.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 7)
        }
        if let message = model.messageText {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(SurfaceColors.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.top, 7)
        }
    }
}

/// Key chips followed by action names (window-design.html `.hints`).
struct KeyHintsView: View {
    let hints: [KeyHint]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 5) {
                    Text(hint.key)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SurfaceColors.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(SurfaceColors.chip))
                    Text(hint.label)
                        .font(.system(size: 11))
                        .foregroundStyle(SurfaceColors.secondary)
                }
                .fixedSize()
            }
        }
        .lineLimit(1)
    }
}
