// The list page (DESIGN.md §4.5 "header row" / "the list has two sections"
// / "Running rows" / "the row's `>` button" / "row selection" / "row click"
// / "fixed footer" / "key hints", §4.6 "History section" / "stars" /
// "bottom panel"; visual spec: docs/window-design.html "list page", "row
// parts", "fixed footer"). Presentation only: every text, state and enabled
// flag comes from `MainSurfaceModel.list` (Core).

import AppKit
import Combine
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
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            if surface == .window {
                // The traffic lights sit here (hidden title bar, §4.5).
                Color.clear.frame(width: SurfaceMetrics.trafficLightsWidth - 8, height: 1)
            }
            ConversationsSearchField(
                text: $model.query,
                isEnabled: !model.list.isFullBuild,
                focusToken: model.searchFocusRequests[surface] ?? 0,
                scale: scale
            )
            // window-design.html `.search`: 24pt tall at 13, level with the
            // 24pt header buttons; it follows the text size, the buttons do
            // not, and the row centers both (§4.5 "text size").
            .frame(height: scale.searchFieldHeight)
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
        .frame(height: scale.headerRowHeight)
        .padding(.top, surface == .window ? scale.windowHeaderTop : scale.headerTop)
        .padding(.bottom, scale.headerBottom)
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
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        let list = model.list
        ScrollView {
            // An eager stack: every row has a real frame, so revealing or
            // restoring any row is exact (History is capped — §9 — so the
            // row count stays small).
            VStack(alignment: .leading, spacing: 0) {
                if let empty = list.emptyStateText {
                    Text(empty)
                        .font(.system(size: scale.listNoteFont))
                        .foregroundStyle(SurfaceColors.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, scale.emptyStateVertical)
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
                        .padding(.bottom, scale.rowGap)
                        .background(ListRowFrameReporter(key: row.id))
                    }
                }
                if let hidden = list.hiddenHistoryText {
                    // §4.6 / window-design.html: the count of rows the
                    // History cap hides — one centered line, not a card,
                    // not selectable.
                    Text(hidden)
                        .font(.system(size: scale.listNoteFont))
                        .foregroundStyle(SurfaceColors.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, scale.hiddenRowsVertical)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, scale.listBottom)
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
    /// Armed by a text size change until the rows report their new frames
    /// (or its fallback fires): a restore from the old frames would land on
    /// the wrong row.
    private var relayoutWait = ListRelayoutWait()
    private var textSizeSubscription: AnyCancellable?

    func attach(model: MainSurfaceModel, surface: MainSurface) {
        self.model = model
        self.surface = surface
        // §4.5 "text size": the row at the top of the visible range stays
        // at the top. The store publishes before the views update, so the
        // anchor is frozen (no recording while a restore is pending) before
        // any row moves, and restored once the rows are laid out again.
        textSizeSubscription = model.textSize.$size
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.textSizeWillChange() }
            }
    }

    private func textSizeWillChange() {
        guard let model, let surface, model.visibleSurface == surface,
              let generation = relayoutWait.arm(hasRows: !rows.isEmpty) else { return }
        pendingRestore = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ListRelayoutWait.fallbackSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.relayoutWait.fallbackFired(generation: generation) else { return }
                self.flushSoon()
            }
        }
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
        relayoutWait.rowsChanged()
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
        guard !relayoutWait.isWaiting, let scrollView, let model,
              !rows.isEmpty || model.list.sections.isEmpty else { return }
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
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.title)
                .font(.system(size: scale.sectionTitleFont, weight: .bold))
            Text("\(section.count)")
                .font(.system(size: scale.sectionCountFont))
                .foregroundStyle(SurfaceColors.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, scale.sectionHeaderTop)
        .padding(.bottom, scale.sectionHeaderBottom)
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
    @Environment(\.surfaceScale) private var scale

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
                .frame(width: scale.rowLeadingSlot, height: scale.rowLeadingSlot)
                .padding(.top, scale.rowLeadingSlotTop)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: scale.rowLineSpacing) {
                Text(row.line1)
                    .font(.system(size: scale.rowLine1Font, weight: row.isLine1Bold ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: scale.rowLine1Height)
                Text(row.line2)
                    .font(.system(size: scale.rowLine2Font))
                    .foregroundStyle(SurfaceColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: scale.rowLine2Height)
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
        .padding(.top, scale.rowCardTop)
        .padding(.bottom, scale.rowCardBottom)
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
                    .font(.system(size: scale.rowPromptFont, design: .monospaced))
                    .opacity(0.8)
                Text(prompt)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // Keep the row height equal (§4.5 / §4.6).
                Text(" ")
            }
        }
        .font(.system(size: scale.rowPromptFont))
        .foregroundStyle(SurfaceColors.secondary)
        .frame(height: scale.rowPromptHeight)
    }

    @ViewBuilder
    private var leadingSlot: some View {
        switch row.leading {
        case .status(let kind, let unreviewed):
            RowSymbolView(kind: kind, unreviewed: unreviewed, spinning: spinning && kind == .working,
                          size: scale.rowLeadingSlot)
        case .star(let isStarred):
            // §4.6: the slot click toggles the star and never selects.
            Button { model.starClicked(sessionID: row.sessionID) } label: {
                StarView(isStarred: isStarred)
                    .opacity(isStarred || hovering ? 1 : 0)
                    .frame(width: scale.rowLeadingSlot, height: scale.rowLeadingSlot)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.leading.tooltip ?? "")
        }
    }
}

/// The History star (window-design.html: 16px at text size 13; outline in
/// the secondary color on hover, yellow fill when starred).
struct StarView: View {
    let isStarred: Bool
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        ZStack {
            if isStarred {
                IconShape(icon: .star).fill(SurfaceColors.starFill)
                IconShape(icon: .star).stroke(SurfaceColors.starLine, style: StrokeStyle(lineWidth: scale.starFilledLine, lineJoin: .round))
            } else {
                IconShape(icon: .star).stroke(SurfaceColors.secondary, style: StrokeStyle(lineWidth: scale.starOutlineLine, lineJoin: .round))
            }
        }
        .frame(width: scale.star, height: scale.star)
    }
}

/// The row's `>` button (§4.5; window-design.html `.ib`: 28×26, radius 6,
/// a 15pt chevron in the secondary color at text size 13; gray ground on
/// hover / press). Selects the row and opens the detail page.
struct RowOpenButton: View {
    let action: () -> Void
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        Button(action: action) {
            SurfaceIconView(icon: .chevronRight, size: scale.rowOpenIcon, lineWidth: scale.rowOpenIconLine)
                .frame(width: scale.rowOpenButtonWidth, height: scale.rowOpenButtonHeight)
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
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(SurfaceColors.line).frame(height: 1)
            StatusLinesView(model: model)
            if !hints.isEmpty {
                KeyHintsView(hints: hints)
                    .padding(.horizontal, 12)
                    .padding(.top, scale.footerHintsTop)
                    .padding(.bottom, scale.footerHintsBottom)
            }
        }
    }
}

/// The warning rows and the message line (shared by the fixed footer and
/// the one-column pages' bottom panels — §4.5).
struct StatusLinesView: View {
    @ObservedObject var model: MainSurfaceModel
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        ForEach(model.warnings, id: \.self) { warning in
            HStack(spacing: 7) {
                Text("\u{26A0}")
                Text(warning.text).lineLimit(1)
            }
            .font(.system(size: scale.statusLineFont))
            .foregroundStyle(SurfaceColors.secondary)
            .padding(.horizontal, 12)
            .padding(.top, scale.statusLineTop)
        }
        if let message = model.messageText {
            Text(message)
                .font(.system(size: scale.messageLineFont))
                .foregroundStyle(SurfaceColors.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.top, scale.statusLineTop)
        }
    }
}

/// Key chips followed by action names (window-design.html `.hints`). When
/// the width runs short, only the hints that fit whole are shown, in order
/// (§4.5 "text size": the bottom panel's buttons come first).
struct KeyHintsView: View {
    let hints: [KeyHint]
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        WholeItemsRow(spacing: 14) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 5) {
                    Text(hint.key)
                        .font(.system(size: scale.keyChipFont, design: .monospaced))
                        .foregroundStyle(SurfaceColors.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, scale.keyChipVertical)
                        .background(RoundedRectangle(cornerRadius: 4).fill(SurfaceColors.chip))
                    Text(hint.label)
                        .font(.system(size: scale.keyLabelFont))
                        .foregroundStyle(SurfaceColors.secondary)
                }
                .fixedSize()
            }
        }
        .lineLimit(1)
        .clipped()
    }
}

/// A left-aligned row that shows its items at their ideal widths and leaves
/// out every item from the first one that does not fit whole. Its minimum
/// width is zero, so a sibling with a higher layout priority keeps its
/// width.
struct WholeItemsRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = sizes.map(\.height).max() ?? 0
        let fullWidth = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        let width = proposal.width.map { min($0, fullWidth) } ?? fullWidth
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var fits = true
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            fits = fits && x + size.width <= bounds.maxX + 0.5
            // An item that does not fit is placed outside the clipped
            // bounds rather than cut in the middle.
            let origin = fits ? x : bounds.maxX + 10_000
            subview.place(at: CGPoint(x: origin, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            if fits { x += size.width + spacing }
        }
    }
}
