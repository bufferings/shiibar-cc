// The list page (DESIGN.md §4.5 "header row" / "the list has three
// sections" / "Running rows" / "row selection" / "row click" / "collapsing
// sections" / "row drag" / "fixed footer" / "key hints", §4.6 "Starred
// section" / "Recent section" / "stars" / "bottom panel"; visual spec:
// docs/window-design.html "list page", "row parts", "collapsing sections
// and the row drag", "fixed footer"). Presentation and mouse tracking
// only: every text, state, enabled flag and drag decision comes from
// `MainSurfaceModel.list` (Core).

import AppKit
import Combine
import ShiibarCcCore
import SwiftUI

/// List + footer (the header row above it is `HeaderRowView`, placed by
/// `MainSurfaceView`). One column: the footer is the warning rows,
/// the message line and the bottom panel (key hints + the selected row's
/// buttons — §4.6 "bottom panel"). Two columns (the left column): the fixed
/// footer with the key hints only (§4.5 "fixed footer").
struct ListPageView: View {
    @ObservedObject var model: MainSurfaceModel
    let surface: MainSurface

    var body: some View {
        VStack(spacing: 0) {
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

/// One button of the header row, right of the search field (§4.5 "header
/// row").
enum HeaderRowButton: Equatable, Hashable {
    case refresh
    case openInWindow
    case openInPopover
    case pin
    case menu

    /// The tooltip; nil = none (the ⌄ chip has none).
    var tooltip: String? {
        switch self {
        case .refresh: return RefreshButtonState.idle.tooltip
        case .openInWindow: return "Open in window"
        case .openInPopover: return "Open in popover"
        case .pin: return "Keep on top"
        case .menu: return nil
        }
    }

    /// The buttons right of the search field, left to right (§4.5 "header
    /// row"): popover = Refresh / `Open in window` / ⌄; window = Refresh /
    /// `Open in popover` / pin / ⌄. Refresh is always the leftmost.
    static func buttons(for surface: MainSurface) -> [HeaderRowButton] {
        switch surface {
        case .popover: return [.refresh, .openInWindow, .menu]
        case .window: return [.refresh, .openInPopover, .pin, .menu]
        }
    }
}

/// The Refresh button's state (§4.5 "header row", §4.6 Refresh): enabled
/// while idle; while a Refresh runs it is disabled (no second trigger),
/// its tooltip reads `Refreshing…`, and its icon turns unless Reduce Motion
/// is on.
struct RefreshButtonState: Equatable {
    let isEnabled: Bool
    let tooltip: String
    let spins: Bool
    /// window-design.html: the disabled button is drawn at 40%, turning or
    /// not.
    let opacity: Double

    static let idle = RefreshButtonState(isRefreshing: false, reduceMotion: false)

    init(isRefreshing: Bool, reduceMotion: Bool) {
        isEnabled = !isRefreshing
        // The idle tooltip is the one place on screen that names the ⌘R shortcut (§4.5 "header row").
        tooltip = isRefreshing ? "Refreshing\u{2026}" : "Refresh (\u{2318}R)"
        spins = isRefreshing && !reduceMotion
        opacity = isRefreshing ? 0.4 : 1
    }

    /// The accessibility name, whatever the state.
    static let accessibilityLabel = "Refresh"
}

/// What the header row shows for a surface and column mode (§4.5 "header
/// row"). In every case the search field fills the row up to the next
/// element; in two columns the hit counter with ‹ › follows it while it is
/// shown, so the field gets shorter by the counter and a gap. One and two
/// columns differ only by the counter.
struct HeaderRowLayout: Equatable {
    enum Element: Hashable {
        case trafficLightSpace
        case searchField
        case hitCounter
        case button(HeaderRowButton)
    }

    let showsTrafficLightSpace: Bool
    let showsHitCounter: Bool
    let buttons: [HeaderRowButton]

    /// `hitCounterAvailable`: the conversation pane shows a conversation
    /// with hits (the counter's own condition, `hitCounterAvailable(...)`).
    /// `fullScreen`: the window is in full screen, where no traffic lights
    /// sit at the row's leading edge, so the search field starts at the
    /// normal padding.
    init(surface: MainSurface, columns: ColumnMode, hitCounterAvailable: Bool, fullScreen: Bool = false) {
        showsTrafficLightSpace = surface == .window && !fullScreen
        showsHitCounter = surface == .window && columns == .two && hitCounterAvailable
        buttons = HeaderRowButton.buttons(for: surface)
    }

    /// Left to right.
    var elements: [Element] {
        var result: [Element] = []
        if showsTrafficLightSpace { result.append(.trafficLightSpace) }
        result.append(.searchField)
        if showsHitCounter { result.append(.hitCounter) }
        result += buttons.map(Element.button)
        return result
    }

    /// The counter shows while a conversation's messages are shown with at
    /// least one hit and no load error (§4.6 "hit navigation").
    /// `conversationShowsMessages`: nil while the pane shows no
    /// conversation.
    static func hitCounterAvailable(conversationShowsMessages: Bool?, hitCount: Int, hasLoadError: Bool) -> Bool {
        conversationShowsMessages == true && hitCount > 0 && !hasLoadError
    }
}

/// The header row (`HeaderRowLayout`). The search field stays at one place
/// in the view tree in every column mode, so a column switch never builds
/// a new one (it would take the latest focus request and move the focus).
struct HeaderRowView: View {
    @ObservedObject var model: MainSurfaceModel
    let surface: MainSurface
    let columns: ColumnMode
    /// The header row is under the one-column detail page.
    let isCoveredByDetailPage: Bool
    @State private var menuAnchor: NSView?
    @Environment(\.surfaceScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: HeaderRowLayout {
        HeaderRowLayout(
            surface: surface,
            columns: columns,
            hitCounterAvailable: HeaderRowLayout.hitCounterAvailable(
                conversationShowsMessages: conversationShowsMessages, hitCount: model.hits.count,
                hasLoadError: model.paneLoadError != nil),
            fullScreen: model.isFullScreen(surface))
    }

    private var conversationShowsMessages: Bool? {
        guard case .conversation(let pane) = model.list.paneContent else { return nil }
        return pane.showsMessages
    }

    var body: some View {
        let layout = self.layout
        // Rendered from `elements`, so the tested order is the drawn one.
        // ForEach identifies each element by its value: the search field is
        // `.searchField` in every column mode, so the same field stays when
        // the hit counter comes and goes. The row's background drags the
        // window from its empty parts (paddings, gaps, the traffic-light
        // space); the search field takes its own clicks.
        HStack(spacing: SurfaceMetrics.headerSpacing) {
            ForEach(layout.elements, id: \.self) { element in
                headerElement(element)
            }
        }
        .padding(.horizontal, SurfaceMetrics.headerSide)
        .frame(height: scale.headerRowHeight)
        // The window: equal space above and below, the row on the traffic
        // lights (§4.5 "header row"). The popover keeps its own paddings.
        .padding(.top, surface == .window ? scale.windowHeaderPadding : scale.headerTop)
        .padding(.bottom, surface == .window ? scale.windowHeaderPadding : scale.headerBottom)
        .background(surface == .window ? WindowDragArea() : nil)
    }

    @ViewBuilder
    private func headerElement(_ element: HeaderRowLayout.Element) -> some View {
        switch element {
        case .trafficLightSpace:
            // The traffic lights sit here (hidden title bar, §4.5).
            Color.clear.frame(width: SurfaceMetrics.trafficLightsWidth - SurfaceMetrics.headerSpacing, height: 1)
        case .searchField:
            ConversationsSearchField(
                text: $model.query,
                isEnabled: !model.list.isFullBuild,
                focusToken: model.searchFocusRequests[surface] ?? 0,
                isKeyViewLoopMember: !isCoveredByDetailPage,
                scale: scale,
                placeholder: model.list.searchPlaceholder
            )
            // window-design.html `.search`: 28pt tall at 13; it and the
            // buttons (24pt at 13) follow the text size, and the row
            // centers both (§4.5 "text size").
            // The field fills the row up to the next element and is the
            // part that gives way, so the counter and the buttons keep
            // their sizes and stay inside the window.
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: scale.searchFieldHeight)
            // window-design.html `.search.dis`: faded while a full index
            // build disables the field (§4.6).
            .opacity(model.list.isFullBuild ? 0.5 : 1)
        case .hitCounter:
            // §4.6 "hit navigation": the same counter and ‹ › as the
            // one-column find bar.
            HStack(spacing: SurfaceMetrics.headerSpacing) {
                Text(model.hitCounterText ?? "")
                    .foregroundStyle(SurfaceColors.secondary)
                    .fixedSize()
                FindNavigationControl(
                    onPrevious: { model.navigateToOlderHit() },
                    onNext: { model.navigateToNewerHit() }
                )
                .fixedSize()
            }
            .font(.system(size: scale.findBarFont))
        case .button(let button):
            headerButton(button)
        }
    }

    @ViewBuilder
    private func headerButton(_ button: HeaderRowButton) -> some View {
        switch button {
        case .refresh:
            // The same Refresh as ⌘R (§4.6). The turning icon is a layer
            // animation inside its own view, so the row is not laid out
            // again while it turns.
            let state = RefreshButtonState(isRefreshing: model.isRefreshing, reduceMotion: reduceMotion)
            Button { model.refresh() } label: {
                RefreshIconView(spins: state.spins, iconSize: scale.headerIcon, lineWidth: scale.headerIconLine)
                    .frame(width: scale.headerButton, height: scale.headerButton)
            }
            .buttonStyle(HoverChipButtonStyle(isEnabled: state.isEnabled))
            .opacity(state.opacity)
            .disabled(!state.isEnabled)
            .help(state.tooltip)
            .accessibilityLabel(RefreshButtonState.accessibilityLabel)
        case .openInWindow:
            Button { model.openInWindowClicked() } label: {
                SurfaceIconView(icon: .window, size: scale.headerIcon, lineWidth: scale.headerIconLine)
                    .frame(width: scale.headerButton, height: scale.headerButton)
            }
            .buttonStyle(HoverChipButtonStyle())
            .foregroundStyle(SurfaceColors.secondary)
            .help(button.tooltip ?? "")
        case .openInPopover:
            // window-design.html `i-popover`: the same size, line width and
            // grounds as `Open in window`.
            Button { model.openInPopoverClicked() } label: {
                SurfaceIconView(icon: .popover, size: scale.headerIcon, lineWidth: scale.headerIconLine)
                    .frame(width: scale.headerButton, height: scale.headerButton)
            }
            .buttonStyle(HoverChipButtonStyle())
            .foregroundStyle(SurfaceColors.secondary)
            .help(button.tooltip ?? "")
        case .pin:
            // §4.5 "pin": OFF = the outline in the secondary color with
            // the other header buttons' hover / press grounds; ON = the
            // accent fill on an accent ground (window-design.html
            // `i-pin`, `.hb.on`).
            Button { model.keepOnTopClicked() } label: {
                SurfaceIconView(icon: .pin, size: scale.headerIcon, lineWidth: scale.pinIconLine, filled: model.keepOnTop)
                    .frame(width: scale.headerButton, height: scale.headerButton)
            }
            .buttonStyle(HoverChipButtonStyle(onTint: model.keepOnTop ? Color.accentColor : nil))
            .foregroundStyle(model.keepOnTop ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(SurfaceColors.secondary))
            .help(button.tooltip ?? "")
        case .menu:
            Button {
                if let menuAnchor { model.menuClicked(anchor: menuAnchor, surface: surface) }
            } label: {
                SurfaceIconView(icon: .chevronDown, size: scale.headerIcon, lineWidth: scale.menuChevronLine)
                    .frame(width: scale.headerButton, height: scale.headerButton)
            }
            .buttonStyle(HoverChipButtonStyle(restingOpacity: 0.10))
            .foregroundStyle(SurfaceColors.secondary)
            .background(MenuAnchorView { menuAnchor = $0 })
        }
    }
}

// MARK: - List

struct ListBodyView: View {
    @ObservedObject var model: MainSurfaceModel
    let surface: MainSurface
    @StateObject private var scroller = ListScroller()
    /// The row drag's floating image, drop line and the reason a row cannot
    /// be dragged (§4.5 "row drag"): published apart from the list, so
    /// following the pointer redraws only them.
    @StateObject private var dragOverlay = ListDragOverlay()
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        let list = model.list
        let blocks = list.blocks
        ScrollView {
            // An eager stack: every row has a real frame, so revealing or
            // restoring any row is exact (Recent is capped — §9 — so the
            // row count stays small).
            // The bands span the list's whole width; every other element
            // sits `SurfaceMetrics.listSide` in from its edges.
            VStack(alignment: .leading, spacing: 0) {
                if let empty = list.emptyStateText {
                    emptyLine(empty)
                }
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    let gap = ListBlockSpacing.gap(before: index, in: blocks, scale: scale)
                    let topLine = ListBlockSpacing.drawsBandTopLine(at: index, columns: list.columns)
                    switch block {
                    case .heading(let heading):
                        SectionHeaderView(heading: heading, drawsTopLine: topLine, model: model)
                            .padding(.horizontal, heading.style == .band ? 0 : SurfaceMetrics.listSide)
                            .padding(.top, gap)
                    case .archiveHeading(let heading):
                        ArchiveHeaderView(heading: heading, drawsTopLine: topLine, model: model)
                            .padding(.top, gap)
                    case .frame(let frame):
                        RowFrameView(frame: frame, model: model)
                            .padding(.horizontal, SurfaceMetrics.listSide)
                            .padding(.top, gap)
                    case .moreLine(let text):
                        // §4.6: the count of rows the Recent cap hides —
                        // one centered line below the frame, not a row,
                        // not selectable.
                        Text(text)
                            .font(.system(size: scale.listNoteFont))
                            .foregroundStyle(SurfaceColors.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, scale.hiddenRowsVertical)
                            .background(ListElementFrameReporter(kind: .moreLine))
                            .padding(.horizontal, SurfaceMetrics.listSide)
                            .padding(.top, gap)
                    case .emptyLine(let text):
                        emptyLine(text)
                            .padding(.top, gap)
                    }
                }
            }
            .padding(.bottom, scale.listBottom)
            // Drawn over the rows without moving them (window-design.html
            // `.dropline`), in list-content coordinates.
            .overlay(alignment: .topLeading) { DropLineView(overlay: dragOverlay) }
            .background(ListScrollProbe(scroller: scroller))
            .coordinateSpace(name: ListScroller.contentSpace)
            .onPreferenceChange(ListRowFramesKey.self) { rows in
                MainActor.assumeIsolated { scroller.rowsChanged(rows) }
            }
            .onPreferenceChange(ListElementFramesKey.self) { elements in
                MainActor.assumeIsolated { scroller.elementsChanged(elements) }
            }
        }
        .overlay(alignment: .topLeading) { CardDragGhostView(model: model, overlay: dragOverlay) }
        .overlay(alignment: .topLeading) { DragRefusalTipView(model: model, overlay: dragOverlay) }
        .onAppear {
            scroller.attach(model: model, surface: surface, overlay: dragOverlay)
            if model.visibleSurface == surface { scroller.requestRestore() }
        }
        .onChange(of: list.cardDrag) {
            scroller.cardDragChanged()
        }
        .onChange(of: model.visibleSurface) { _, visible in
            if visible == surface { scroller.requestRestore() }
        }
        .onChange(of: model.scrollSelectionRequest) {
            scroller.requestReveal()
        }
        .onChange(of: model.scrollToTopRequest) {
            scroller.requestScrollToTop()
        }
        .onChange(of: model.scrollRestoreRequest) {
            scroller.requestRestore()
        }
    }

    /// The empty-state line (§4.6), and the Archive view's line under its
    /// band.
    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: scale.listNoteFont))
            .foregroundStyle(SurfaceColors.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, scale.emptyStateVertical)
            .padding(.horizontal, SurfaceMetrics.listSide)
    }
}

/// The vertical space between the list's blocks (window-design.html
/// "collapsing sections and the row drag": spacing between elements; §9). A
/// band wants 8 above and 8 below, whatever the text size; a heading under
/// History 6 above and 4 below (following the text size); a frame of rows,
/// the `N more` line and the Archive view's line nothing. Two neighbors are
/// apart by the larger of the upper one's space below and the lower one's
/// space above. A band that is the list's first element sits right under
/// the header row, with no space above it (§4.5 "the list has three
/// sections").
enum ListBlockSpacing {
    static func gap(before index: Int, in blocks: [ListBlock], scale: SurfaceScale) -> CGFloat {
        let top = margins(blocks[index], scale: scale).top
        guard index > 0 else { return blocks[index].isBand ? 0 : top }
        return max(margins(blocks[index - 1], scale: scale).bottom, top)
    }

    /// Whether the band at `index` draws its top line: not the first band in
    /// two columns, where the line under the header row is the boundary
    /// (§4.5 "the list has three sections").
    static func drawsBandTopLine(at index: Int, columns: ColumnMode) -> Bool {
        !(index == 0 && columns == .two)
    }

    private static func margins(_ block: ListBlock, scale: SurfaceScale) -> (top: CGFloat, bottom: CGFloat) {
        if block.isBand { return (SurfaceMetrics.sectionBandGap, SurfaceMetrics.sectionBandGap) }
        switch block {
        case .heading:
            return (scale.subHeadingTop, scale.subHeadingBottom)
        case .archiveHeading, .frame, .moreLine, .emptyLine:
            return (0, 0)
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

/// Every list element's frame in the list content (feeds the row drag).
private struct ListElementFramesKey: PreferenceKey {
    static let defaultValue: [ListElementExtent] = []
    static func reduce(value: inout [ListElementExtent], nextValue: () -> [ListElementExtent]) {
        value.append(contentsOf: nextValue())
    }
}

private struct ListElementFrameReporter: View {
    let kind: ListElementKind

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named(ListScroller.contentSpace))
            Color.clear.preference(
                key: ListElementFramesKey.self,
                value: [ListElementExtent(
                    kind: kind, top: Double(frame.minY), bottom: Double(frame.maxY),
                    minX: Double(frame.minX), maxX: Double(frame.maxX))]
            )
        }
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
    /// The Archive view was shown: it starts at its top (§4.6).
    private var pendingTop = false
    /// Armed by a text size change until the rows report their new frames
    /// (or its fallback fires): a restore from the old frames would land on
    /// the wrong row.
    private var relayoutWait = ListRelayoutWait()
    private var textSizeSubscription: AnyCancellable?

    // MARK: Row drag (§4.5 "row drag")

    private weak var dragOverlay: ListDragOverlay?
    /// Every element's frame in list-content coordinates.
    private var elements: [ListElementExtent] = []
    private var mouseMonitor: Any?
    /// The press on a row not yet decided as a drag or not.
    private var press: RowPress?
    /// A drag this list started is in progress (until the button is
    /// released, or Core cancels it).
    private var isDragging = false
    /// The pointer's latest window location during a drag.
    private var dragPointer: NSPoint?
    private var autoScrollTimer: Timer?
    private var lastAutoScrollTick: TimeInterval?
    /// The mouse buttons held now (`NSEvent.pressedMouseButtons`); tests
    /// replace it.
    var pressedMouseButtons: () -> Int = { NSEvent.pressedMouseButtons }
    /// The current time in seconds (system uptime); tests replace it.
    var currentTime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// How long the button may read as up during a drag before the drag is
    /// cancelled for a release that never arrived: the release event can
    /// reach the app after the button state already reads as up, and a
    /// release on a target must still drop (§4.5 "row drag": cancel).
    static let lostReleaseGraceSeconds: TimeInterval = 0.25
    /// When an auto-scroll tick first saw the button up during the drag;
    /// nil while it reads as down.
    private var buttonUpSince: TimeInterval?

    private struct RowPress {
        let key: UnifiedRowKey
        let windowPoint: NSPoint
        /// The press relative to the row's top-left: the floating image
        /// keeps it under the pointer.
        let grab: CGPoint
        let rowWidth: CGFloat
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        autoScrollTimer?.invalidate()
    }

    func attach(model: MainSurfaceModel, surface: MainSurface, overlay: ListDragOverlay) {
        self.model = model
        self.surface = surface
        self.dragOverlay = overlay
        if mouseMonitor == nil {
            // Mouse tracking for the drag: no system drag and drop and no
            // pasteboard (§4.5). Every event continues unchanged, so a
            // click still reaches the row.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMouse(event) }
                return event
            }
        }
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
            MainActor.assumeIsolated {
                self?.recordAnchor()
                // §4.5 "row drag": a scroll moves the list under the
                // pointer, so the target is worked out again — after the
                // layout pass this notification may arrive in.
                self?.updateDragSoon()
            }
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

    /// Scroll to the list's top (the Archive view was shown — §4.6).
    func requestScrollToTop() {
        pendingTop = true
        pendingRestore = false
        flushSoon()
    }

    /// Reveal the selected row by the minimum scroll (§4.5).
    func requestReveal() {
        pendingReveal = true
        flushSoon()
    }

    /// Runs after the current SwiftUI update, so the row frames reflect it.
    private func flushSoon() {
        guard pendingRestore || pendingReveal || pendingTop else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        guard !relayoutWait.isWaiting, let scrollView, let model,
              !rows.isEmpty || model.list.visibleRows.isEmpty else { return }
        let switchScroll = pendingTop || pendingRestore
        if pendingTop {
            pendingTop = false
            setTop(0, in: scrollView)
        }
        if pendingRestore {
            if let anchor = model.listScrollAnchor, let viewport = viewport() {
                if let top = anchor.restoredTop(viewport: viewport, rows: rows) {
                    pendingRestore = false
                    setTop(top, in: scrollView)
                } else if !model.list.visibleRows.contains(where: { $0.id == anchor.key }) {
                    // The row left the list: the scroll stays where it is.
                    pendingRestore = false
                }
                // Otherwise the row is in the list but not laid out yet (the
                // list just switched back from the Archive view): the next
                // row-frame update retries.
            } else {
                pendingRestore = false
            }
        }
        if switchScroll, !pendingTop, !pendingRestore, model.visibleSurface == surface {
            model.listScrollRestoreDone()
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
            let isFirstRow = row.key == rows.min(by: { $0.top < $1.top })?.key
            if let top = ListReveal.revealTop(viewport: viewport, row: row, isFirstRow: isFirstRow) {
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

    func elementsChanged(_ elements: [ListElementExtent]) {
        self.elements = elements
        // §4.5 "row drag": the list changed under the pointer.
        updateDragSoon()
    }

    /// Core's drag changed (started, its target moved, ended or cancelled).
    func cardDragChanged() {
        updateDragSoon()
    }

    /// Both callers run inside a view update, where reporting the pointer
    /// to the model (a published change) must not happen: the next main
    /// queue turn does it.
    private func updateDragSoon() {
        guard isDragging else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateDrag() }
        }
    }

    /// A drag this list is tracking (until the release, or Core ends it).
    var isTrackingDrag: Bool { isDragging }

    func handleMouse(_ event: NSEvent) {
        // A release always ends this list's tracking, even when the surface
        // closed or Core cancelled the drag while the button was held, so
        // the next press starts clean.
        if event.type == .leftMouseUp, isDragging {
            press = nil
            stopDrag()
            if let model, model.list.cardDrag != nil {
                dragPointer = event.locationInWindow
                if let point = contentPoint(event.locationInWindow) {
                    model.cardDragMoved(ListPointerHitTest.hit(y: point.y, insideList: isInsideList(point), elements: elements))
                }
                model.cardDragEnded()
            }
            dragPointer = nil
            return
        }
        if event.type == .leftMouseDown, isDragging {
            // The release never arrived (§4.5 "row drag": cancel): a new
            // press ends the drag without a drop.
            cancelDrag()
        }
        guard let model, let surface, model.visibleSurface == surface,
              let scrollView, let window = scrollView.window, event.window === window else { return }
        switch event.type {
        case .leftMouseDown:
            press = nil
            dragOverlay?.setTip(nil)
            // Only a press on a row on screen: not on the one-column detail
            // page over the list, and not on a row scrolled out of the
            // list's visible area (under the header row or the footer).
            guard !isDragging, model.list.isListVisible,
                  let point = contentPoint(event.locationInWindow), isInsideList(point),
                  let row = ListPointerHitTest.pressedRow(x: point.x, y: point.y, elements: elements),
                  let frame = elements.first(where: { $0.kind == .row(row.key) }) else { return }
            let location = event.locationInWindow
            press = RowPress(
                key: row.key, windowPoint: location,
                grab: CGPoint(x: point.x - frame.minX, y: point.y - frame.top),
                rowWidth: CGFloat(frame.maxX - frame.minX))
            model.rowPressed(row.key, clickCount: event.clickCount, onStar: row.onStar,
                             x: Double(location.x), y: Double(location.y))
        case .leftMouseDragged:
            if isDragging {
                dragPointer = event.locationInWindow
                updateDrag()
                return
            }
            guard let press else { return }
            let location = event.locationInWindow
            guard CardDragMetrics.hasMovedFarEnough(
                fromX: Double(press.windowPoint.x), fromY: Double(press.windowPoint.y),
                toX: Double(location.x), toY: Double(location.y)) else { return }
            // Core decides once per press: a drag, the reason the row
            // cannot be dragged, or nothing.
            self.press = nil
            let refusalBefore = model.list.dragRefusal
            model.rowPressDragged(x: Double(location.x), y: Double(location.y))
            if model.list.cardDrag?.key == press.key {
                isDragging = true
                buttonUpSince = nil
                dragPointer = location
                dragOverlay?.begin(key: press.key, grab: press.grab, width: press.rowWidth)
                startAutoScroll()
                updateDrag()
            } else if let refusal = model.list.dragRefusal, refusal != refusalBefore,
                      let point = overlayPoint(location) {
                // Shown where the pointer is now; it does not follow it.
                dragOverlay?.setTip(point)
            }
        case .leftMouseUp:
            if press != nil {
                press = nil
                model.rowPressReleased()
            }
        default:
            break
        }
    }

    /// Re-hit the pointer, report it, and place the floating image and the
    /// line. Ends this list's tracking when Core has no drag any more.
    private func updateDrag() {
        guard isDragging else { return }
        guard let model, model.list.cardDrag != nil else {
            stopDrag()
            return
        }
        guard let pointer = dragPointer, let point = contentPoint(pointer) else { return }
        model.cardDragMoved(ListPointerHitTest.hit(y: point.y, insideList: isInsideList(point), elements: elements))
        if let overlay = overlayPoint(pointer) {
            dragOverlay?.move(pointerInList: overlay)
        }
        dragOverlay?.setLine(dropLine(for: model.list.cardDrag?.indicator))
    }

    /// Ends this list's drag without a drop (§4.5 "row drag": cancel).
    private func cancelDrag() {
        stopDrag()
        model?.cardDragCancelled()
    }

    /// A window location relative to the scroll view's top-left — the
    /// origin of the overlays drawn over the list: the clip view's bounds
    /// origin, which includes any content inset.
    private func overlayPoint(_ windowPoint: NSPoint) -> CGPoint? {
        guard let scrollView, let document = scrollView.documentView, let point = contentPoint(windowPoint) else { return nil }
        let clip = scrollView.contentView.bounds
        let top = document.isFlipped ? Double(clip.minY) : Double(document.bounds.height - clip.maxY)
        return CGPoint(x: point.x - Double(clip.minX), y: point.y - top)
    }

    private func stopDrag() {
        isDragging = false
        dragPointer = nil
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        lastAutoScrollTick = nil
        buttonUpSince = nil
        dragOverlay?.end()
    }

    /// The drop line's place (window-design.html `.dropline`): centered on
    /// the top edge of the row it goes before — the divider between two
    /// rows, or the first row's top edge — or on the last Starred row's
    /// bottom edge for the end. It runs from 3pt left of the frame to the
    /// frame's right edge (the frame's border is 1pt outside the rows).
    func dropLine(for indicator: CardDropIndicator?) -> ListDragOverlay.Line? {
        guard case .line(let before) = indicator, let model else { return nil }
        let starredKeys = Set(model.list.starredRows.map(\.id))
        let starred = elements.filter {
            if case .row(let row) = $0.kind { return starredKeys.contains(row) }
            return false
        }.sorted { $0.top < $1.top }
        let y: Double
        let reference: ListElementExtent
        if let before {
            guard let row = starred.first(where: { $0.kind == .row(.conversation(sessionID: before)) }) else { return nil }
            reference = row
            y = row.top
        } else {
            guard let last = starred.last else { return nil }
            reference = last
            y = last.bottom
        }
        let border = SurfaceMetrics.rowFrameBorder
        return ListDragOverlay.Line(
            y: CGFloat(y),
            minX: CGFloat(reference.minX) - border - SurfaceMetrics.dropLineLeadOut,
            maxX: CGFloat(reference.maxX) + border)
    }

    /// §4.5 / §9: while the pointer is near the top or the bottom of the
    /// list, scroll that way (`CardDragAutoScroll`).
    private func startAutoScroll() {
        autoScrollTimer?.invalidate()
        lastAutoScrollTick = currentTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoScrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    func autoScrollTick() {
        let now = currentTime()
        let elapsed = now - (lastAutoScrollTick ?? now)
        lastAutoScrollTick = now
        // Core ended the drag (the surface closed, the window lost key, a
        // search started …): the tracking and this timer stop.
        if isDragging, model?.list.cardDrag == nil {
            stopDrag()
            return
        }
        // The button reads as up: the release may still be on its way, so
        // the drag is cancelled only once it has read as up for the grace
        // period without a release (§4.5 "row drag": cancel). No scrolling
        // meanwhile.
        if isDragging {
            if pressedMouseButtons() & 1 == 0 {
                if let since = buttonUpSince {
                    if now - since >= Self.lostReleaseGraceSeconds {
                        cancelDrag()
                    }
                } else {
                    buttonUpSince = now
                }
                return
            }
            buttonUpSince = nil
        }
        guard isDragging, let model, let scrollView, let pointer = dragPointer,
              let point = contentPoint(pointer), let viewport = viewport() else { return }
        let velocity = CardDragAutoScroll.velocity(
            pointerY: point.y - viewport.top, viewportHeight: viewport.height, textSize: model.textSize.size)
        guard velocity != 0, elapsed > 0 else { return }
        let top = viewport.clampedTop(viewport.top + velocity * min(elapsed, 0.1))
        guard top != viewport.top else { return }
        setTop(top, in: scrollView)
        updateDrag()
    }

    /// A window location in list-content coordinates (y down), or nil
    /// without a scroll view.
    private func contentPoint(_ windowPoint: NSPoint) -> (x: Double, y: Double)? {
        guard let document = scrollView?.documentView else { return nil }
        let point = document.convert(windowPoint, from: nil)
        let y = document.isFlipped ? point.y : document.bounds.height - point.y
        return (Double(point.x), Double(y))
    }

    /// Whether a list-content point is inside the list's visible area.
    private func isInsideList(_ point: (x: Double, y: Double)) -> Bool {
        guard let viewport = viewport(), let xRange = visibleXRange else { return false }
        return point.y >= viewport.top && point.y <= viewport.top + viewport.height && xRange.contains(point.x)
    }

    /// The horizontal extent of the list's visible area, in list-content
    /// coordinates.
    private var visibleXRange: ClosedRange<Double>? {
        guard let clip = scrollView?.contentView else { return nil }
        return Double(clip.bounds.minX)...Double(clip.bounds.maxX)
    }

    /// Keep the shared scroll position (§4.5) — only the surface on screen
    /// writes it.
    private func recordAnchor() {
        guard !pendingRestore, let model, !model.isListScrollRestorePending, let surface,
              model.visibleSurface == surface,
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

/// A heading (§4.5 "the list has three sections" / "collapsing sections" /
/// "row drag", §8.63; window-design.html `.rows .sec`, `.sec.sub`): the
/// Running mark, the bold name, the count, the drag's hint, and the chevron
/// at the right end. Running and History are bands across the list's whole
/// width (`SectionBandView`); Starred and Recent are text and a line,
/// between the frames' edges. In both the name starts where the rows' text
/// does and the chevron ends where the rows' symbol-and-time column does. A
/// click anywhere on the band, or anywhere in the text-and-line heading's
/// width, opens or closes it (Core decides). It has no hover look.
struct SectionHeaderView: View {
    let heading: ListHeadingModel
    /// The band draws its top line (`ListBlockSpacing.drawsBandTopLine`).
    let drawsTopLine: Bool
    let model: MainSurfaceModel
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        switch heading.style {
        case .band:
            SectionBandView(drawsTopLine: drawsTopLine) {
                HStack(alignment: .center, spacing: SurfaceMetrics.sectionBandSpacing) {
                    if heading.showsAttentionMark {
                        Circle()
                            .fill(SurfaceColors.runningMark)
                            .frame(width: scale.runningMark, height: scale.runningMark)
                    }
                    name
                    count
                    Spacer(minLength: 0)
                    chevron
                }
            }
            .onTapGesture { model.headingClicked(heading.heading) }
            .background(ListElementFrameReporter(kind: .heading(heading.heading)))
        case .sub:
            subHeading
        }
    }

    private var name: some View {
        Text(heading.title)
            .font(.system(size: scale.sectionTitleFont, weight: .bold))
            .foregroundStyle(heading.isOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(SurfaceColors.secondary))
    }

    @ViewBuilder
    private var count: some View {
        if let count = heading.countText {
            Text(count)
                .font(.system(size: scale.sectionCountFont))
                .foregroundStyle(SurfaceColors.secondary)
        }
    }

    /// While searching the chevron is not shown; its box keeps its place.
    private var chevron: some View {
        Group {
            if heading.isCollapsible {
                SurfaceIconView(
                    icon: heading.isOpen ? .chevronDown : .chevronRight,
                    size: scale.sectionChevronIcon,
                    lineWidth: scale.sectionChevronLine)
                    .foregroundStyle(SurfaceColors.secondary)
            } else {
                Color.clear
            }
        }
        .frame(width: scale.sectionChevronBox, height: scale.sectionChevronBox)
    }

    /// Starred and Recent (`.sec.sub`): the name, the count, a 1pt line in
    /// the separator color across the width left (up to the drag's hint
    /// while it shows), and the chevron. As the row drag's drop target it
    /// gets the selection's pale accent ground and a 2pt accent border in
    /// a rounded shape, the line still drawn (`.sec.over`).
    private var subHeading: some View {
        let shape = RoundedRectangle(cornerRadius: SurfaceMetrics.subHeadingRadius)
        return HStack(alignment: .center, spacing: SurfaceMetrics.sectionBandSpacing) {
            name
            count
            Rectangle()
                .fill(SurfaceColors.line)
                .frame(height: SurfaceMetrics.sectionBandLine)
                .frame(minWidth: SurfaceMetrics.sectionBandSpacing, maxWidth: .infinity)
            if let hint = heading.hint {
                Text(hint)
                    .font(.system(size: scale.sectionCountFont, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            }
            chevron
        }
        .lineLimit(1)
        .padding(.leading, SurfaceMetrics.subHeadingLeading)
        .padding(.trailing, SurfaceMetrics.subHeadingTrailing)
        .padding(.vertical, scale.subHeadingVertical)
        .background(shape.fill(heading.isDropTarget ? SurfaceColors.selectionTint : .clear))
        .overlay {
            if heading.isDropTarget {
                shape.strokeBorder(Color.accentColor, lineWidth: SurfaceMetrics.dropHeaderBorder)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.headingClicked(heading.heading) }
        .background(ListElementFrameReporter(kind: .heading(heading.heading)))
    }
}

/// A band (§4.5 "the list has three sections", §9; window-design.html
/// `.rows .sec`): the list's whole width, square corners, 30pt tall at 13
/// with a 1pt line in the separator color along its top and bottom edges
/// (the top one left out when `drawsTopLine` is false), the band's gray
/// over the list's ground, the content between the 22pt and 19pt insets.
/// The whole band takes the click.
struct SectionBandView<Content: View>: View {
    let drawsTopLine: Bool
    @ViewBuilder let content: Content
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        content
            .lineLimit(1)
            .padding(.leading, SurfaceMetrics.sectionBandLeading)
            .padding(.trailing, SurfaceMetrics.sectionBandTrailing)
            .frame(maxWidth: .infinity)
            .frame(height: scale.sectionBandContentHeight)
            .padding(.vertical, SurfaceMetrics.sectionBandLine)
            .background(SurfaceColors.sectionBand)
            .overlay(alignment: .top) {
                if drawsTopLine {
                    Rectangle().fill(SurfaceColors.line).frame(height: SurfaceMetrics.sectionBandLine)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(SurfaceColors.line).frame(height: SurfaceMetrics.sectionBandLine)
            }
            .contentShape(Rectangle())
    }
}

/// The Archive view's band (§4.6 "Archive view"; window-design.html
/// `.sec.arch`): a left-pointing chevron in the chevron's box, `Archived`
/// and the count; no chevron at the right end. A click anywhere on it
/// returns to the normal list without moving the keyboard focus.
struct ArchiveHeaderView: View {
    let heading: ArchiveHeadingModel
    let drawsTopLine: Bool
    let model: MainSurfaceModel
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        SectionBandView(drawsTopLine: drawsTopLine) {
            HStack(alignment: .center, spacing: SurfaceMetrics.sectionBandSpacing) {
                SurfaceIconView(icon: .back, size: scale.sectionChevronIcon, lineWidth: scale.sectionChevronLine)
                    .foregroundStyle(SurfaceColors.secondary)
                    .frame(width: scale.sectionChevronBox, height: scale.sectionChevronBox)
                Text(ArchiveHeadingModel.title)
                    .font(.system(size: scale.sectionTitleFont, weight: .bold))
                if let count = heading.countText {
                    Text(count)
                        .font(.system(size: scale.sectionCountFont))
                        .foregroundStyle(SurfaceColors.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .onTapGesture { model.archiveHeadingClicked() }
    }
}

/// A section's rows in one frame (§4.5 "the list has three sections";
/// window-design.html `.group`): a rounded 1pt border and the frame's
/// ground, the rows touching each other with a divider between two rows.
/// While a Recent row is dragged and the drop is shown by a line, the
/// Starred frame's border is 2pt accent (`.group.over`).
struct RowFrameView: View {
    let frame: ListFrameModel
    @ObservedObject var model: MainSurfaceModel

    var body: some View {
        let list = model.list
        let shape = RoundedRectangle(cornerRadius: SurfaceMetrics.rowFrameRadius)
        let border = SurfaceMetrics.rowFrameBorder
        VStack(spacing: 0) {
            ForEach(Array(frame.rows.enumerated()), id: \.element.id) { index, row in
                RowView(
                    row: row,
                    position: RowView.Position(isFirst: index == 0, isLast: index == frame.rows.count - 1),
                    isSelected: list.selection?.key == row.id,
                    isSelectionActive: list.isSelectionActive,
                    isLifted: list.cardDrag?.key == row.id,
                    isDimmed: list.isRowDimmed(row),
                    showsHover: list.cardDrag == nil,
                    spinning: model.isSpinnerActive,
                    model: model
                )
                .background(ListElementFrameReporter(kind: .row(row.id)))
                .background(ListRowFrameReporter(key: row.id))
            }
        }
        .padding(border)
        .background(shape.fill(SurfaceColors.card))
        .overlay(shape.strokeBorder(frame.isEmphasized ? Color.accentColor : SurfaceColors.cardBorder, lineWidth: border))
        .overlay {
            if frame.isEmphasized {
                RoundedRectangle(cornerRadius: SurfaceMetrics.rowFrameRadius + border)
                    .strokeBorder(Color.accentColor, lineWidth: border)
                    .padding(-border)
            }
        }
    }
}

/// The row drag's floating image, drop line and the reason a row cannot be
/// dragged (§4.5 "row drag"; window-design.html `.ghost`, `.dropline`,
/// `.tip`), set by `ListScroller`.
@MainActor
final class ListDragOverlay: ObservableObject {
    struct Ghost: Equatable {
        let key: UnifiedRowKey
        /// The press relative to the row's top-left.
        let grab: CGPoint
        /// The row's width (the frame is its border wider).
        let width: CGFloat
        /// The pointer relative to the list's visible top-left.
        var pointer: CGPoint?
    }

    /// The line's vertical center and horizontal extent, in list-content
    /// coordinates.
    struct Line: Equatable {
        let y: CGFloat
        let minX: CGFloat
        let maxX: CGFloat
    }

    @Published private(set) var ghost: Ghost?
    @Published private(set) var line: Line?
    /// Where the pointer was when the reason a row cannot be dragged
    /// appeared, relative to the list's visible top-left.
    @Published private(set) var tip: CGPoint?

    func begin(key: UnifiedRowKey, grab: CGPoint, width: CGFloat) {
        ghost = Ghost(key: key, grab: grab, width: width, pointer: nil)
        line = nil
    }

    func move(pointerInList pointer: CGPoint) {
        guard var ghost, ghost.pointer != pointer else { return }
        ghost.pointer = pointer
        self.ghost = ghost
    }

    func setLine(_ line: Line?) {
        if line != self.line { self.line = line }
    }

    func setTip(_ tip: CGPoint?) {
        if tip != self.tip { self.tip = tip }
    }

    func end() {
        if ghost != nil { ghost = nil }
        if line != nil { line = nil }
    }
}

/// The row image that follows the pointer, keeping the press's place on
/// the row under it: the row alone in a frame of the same width, without
/// the selection ground (opacity and shadow: §9, window-design.html
/// `.ghost`). It takes no clicks.
private struct CardDragGhostView: View {
    @ObservedObject var model: MainSurfaceModel
    @ObservedObject var overlay: ListDragOverlay

    var body: some View {
        if let ghost = overlay.ghost, let pointer = ghost.pointer,
           let drag = model.list.cardDrag, drag.key == ghost.key,
           let row = model.list.visibleRows.first(where: { $0.id == ghost.key }) {
            let border = SurfaceMetrics.rowFrameBorder
            let shape = RoundedRectangle(cornerRadius: SurfaceMetrics.rowFrameRadius)
            RowView(
                row: row,
                position: RowView.Position(isFirst: true, isLast: true),
                isSelected: false,
                isSelectionActive: model.list.isSelectionActive,
                showsHover: false,
                spinning: model.isSpinnerActive,
                model: model,
                reportsStarFrame: false
            )
            .frame(width: ghost.width)
            .padding(border)
            .background(shape.fill(SurfaceColors.card))
            .overlay(shape.strokeBorder(SurfaceColors.cardBorder, lineWidth: border))
            .opacity(CardDragMetrics.ghostOpacity)
            .shadow(color: .black.opacity(0.22), radius: 11, x: 0, y: 8)
            .offset(x: pointer.x - ghost.grab.x - border, y: pointer.y - ghost.grab.y - border)
            .allowsHitTesting(false)
        }
    }
}

/// The drop line (window-design.html `.dropline`): a 2pt accent line with
/// an 8pt ring at its left end, the ring filled with the list's ground.
private struct DropLineView: View {
    @ObservedObject var overlay: ListDragOverlay

    var body: some View {
        if let line = overlay.line {
            let ring = SurfaceMetrics.dropRingDiameter
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, line.maxX - line.minX), height: SurfaceMetrics.dropLineWidth)
                    .offset(x: line.minX, y: line.y - SurfaceMetrics.dropLineWidth / 2)
                Circle()
                    .fill(SurfaceColors.listBackground)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: SurfaceMetrics.dropRingLine))
                    .frame(width: ring, height: ring)
                    .offset(x: line.minX - SurfaceMetrics.dropLineLeadOut, y: line.y - ring / 2)
            }
            .allowsHitTesting(false)
        }
    }
}

/// The reason a row cannot be dragged (§4.5 "row drag"; window-design.html
/// `.tip`): one line on a dark rounded ground, its top-left corner right of
/// and below where the pointer was, kept inside the list's visible area.
/// Core clears it after §9's time and at the next press. It takes no
/// clicks.
private struct DragRefusalTipView: View {
    @ObservedObject var model: MainSurfaceModel
    @ObservedObject var overlay: ListDragOverlay
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        if let refusal = model.list.dragRefusal, let point = overlay.tip {
            ClampedPlacement(point: CGPoint(
                x: point.x + SurfaceMetrics.refusalTipOffsetX, y: point.y + SurfaceMetrics.refusalTipOffsetY)) {
                Text(refusal.text)
                    .font(.system(size: scale.refusalTipFont))
                    .foregroundStyle(SurfaceColors.refusalTipText)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, SurfaceMetrics.refusalTipHorizontal)
                    .padding(.vertical, scale.refusalTipVertical)
                    .background(
                        RoundedRectangle(cornerRadius: SurfaceMetrics.refusalTipRadius)
                            .fill(SurfaceColors.refusalTipGround))
                    .shadow(color: .black.opacity(0.22), radius: 11, x: 0, y: 8)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Places its one subview with its top-left corner at `point`, moved back
/// inside its own bounds where it would stick out.
private struct ClampedPlacement: Layout {
    let point: CGPoint

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let x = min(max(bounds.minX, bounds.minX + point.x), max(bounds.minX, bounds.maxX - size.width))
            let y = min(max(bounds.minY, bounds.minY + point.y), max(bounds.minY, bounds.maxY - size.height))
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

/// One row in its section's frame (§4.5 "the list has three sections" /
/// §4.6): three lines on the left, starting at the row's left padding, and
/// the symbol-and-time column on the right; a divider above it unless it is
/// the frame's first row. Selection and hover change the row's ground only,
/// kept inside the frame's corners on the first and the last row. A click
/// anywhere on the row but the star selects it; whether the click is part
/// of a double-click (Jump / Resume, or Branch with ⌘) is decided in Core
/// from the press the mouse-down monitor reported (§4.5).
struct RowView: View {
    struct Position: Equatable {
        let isFirst: Bool
        let isLast: Bool
    }

    let row: UnifiedListRow
    let position: Position
    let isSelected: Bool
    /// The surface is key and the list has focus: the selected row is
    /// accent; otherwise gray (§4.5 "row selection").
    let isSelectionActive: Bool
    /// The row being dragged, left in place faded (§4.5 "row drag", §9).
    var isLifted = false
    /// A row that cannot be a drop position during a drag (§9).
    var isDimmed = false
    /// No hover look during a row drag (§4.5 "row drag").
    var showsHover = true
    let spinning: Bool
    let model: MainSurfaceModel
    /// The list's rows report their star box for the drag's press test;
    /// the floating image does not.
    var reportsStarFrame = true
    @State private var hovering = false
    @Environment(\.surfaceScale) private var scale

    private var isHovered: Bool { hovering && showsHover }

    /// The row's ground: the selection tint (accent or gray), else the
    /// hover gray; a selected row keeps its ground on hover.
    private var ground: Color {
        if isSelected {
            return isSelectionActive ? SurfaceColors.selectionTint : SurfaceColors.inactiveSelectionTint
        }
        return isHovered ? SurfaceColors.rowHover : .clear
    }

    private var opacity: Double {
        if isLifted { return CardDragMetrics.liftedOpacity }
        if isDimmed { return CardDragMetrics.dimmedOpacity }
        return 1
    }

    var body: some View {
        let radius = SurfaceMetrics.rowInnerRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: position.isFirst ? radius : 0,
            bottomLeadingRadius: position.isLast ? radius : 0,
            bottomTrailingRadius: position.isLast ? radius : 0,
            topTrailingRadius: position.isFirst ? radius : 0)
        HStack(alignment: .center, spacing: SurfaceMetrics.rowColumnSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(row.labelLine)
                    .font(.system(size: scale.rowLabelFont))
                    .foregroundStyle(SurfaceColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: scale.rowLabelHeight)
                // §4.5: the title is bold on every row; unreviewed is shown
                // only by the badge on the status symbol.
                Text(row.title)
                    .font(.system(size: scale.rowTitleFont, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: scale.rowTitleHeight)
                    .padding(.top, scale.rowLabelTitleSpacing)
                promptLine
                    .padding(.top, scale.rowTitlePromptSpacing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            symbolTimeColumn
                .layoutPriority(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, SurfaceMetrics.rowLeading)
        .padding(.trailing, SurfaceMetrics.rowTrailing)
        .padding(.top, scale.rowTop)
        .padding(.bottom, scale.rowBottom)
        .background(shape.fill(ground))
        .overlay(alignment: .top) {
            // The divider: from the rows' text to the frame's right edge,
            // drawn in the row's top 1pt (it adds no height).
            if !position.isFirst {
                Rectangle()
                    .fill(SurfaceColors.cardBorder)
                    .frame(height: SurfaceMetrics.rowFrameBorder)
                    .padding(.leading, SurfaceMetrics.rowLeading)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.rowClicked(row.id) }
        .opacity(opacity)
    }

    /// The bottom line: the last prompt, or an empty line that keeps the row height
    /// equal (§4.5 / §4.6).
    private var promptLine: some View {
        Text(row.lastPrompt ?? " ")
            .font(.system(size: scale.rowPromptFont))
            .foregroundStyle(SurfaceColors.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: scale.rowPromptHeight)
    }

    /// The symbol-and-time column (§4.5 "the list has three sections", §9,
    /// §8.63): the symbol boxes at the top, level with the label line, and
    /// the elapsed time at the bottom, level with the last prompt, both
    /// against the column's right edge — so the more button, a Running
    /// row's status symbol and the elapsed time end at the same place on
    /// every row. The elapsed time takes the label's size and color (§4.5)
    /// and is never truncated: when it is wider than the column, the column
    /// widens to fit it and the three lines end earlier.
    private var symbolTimeColumn: some View {
        let boxes = row.symbol.boxes
        return VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: SurfaceMetrics.rowSymbolBoxSpacing) {
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                    columnBox(box)
                        .frame(width: scale.rowSymbol, height: scale.rowSymbol)
                }
            }
            .padding(.top, scale.rowSymbolTop)
            Spacer(minLength: 0)
            Text(row.elapsedText)
                .font(.system(size: scale.rowLabelFont))
                .foregroundStyle(SurfaceColors.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(height: scale.rowPromptHeight)
        }
        .frame(minWidth: scale.rowSymbolColumnWidth(boxCount: boxes.count), maxHeight: .infinity,
               alignment: .trailing)
    }

    @ViewBuilder
    private func columnBox(_ box: RowColumnBox) -> some View {
        switch box {
        case .status:
            if case .status(let kind, let unreviewed) = row.symbol {
                RowSymbolView(kind: kind, unreviewed: unreviewed, spinning: spinning && kind == .working,
                              size: scale.rowSymbol)
            }
        case .star:
            if case .star(let isStarred) = row.symbol {
                // §4.6: a click on the star toggles it and never selects the
                // row (nor counts toward a double-click). The star is drawn
                // centered in the symbol box, and the whole box reacts to
                // the click (§4.6 "stars").
                Button { model.starClicked(sessionID: row.sessionID) } label: {
                    StarView(isStarred: isStarred)
                        .opacity(isStarred || isHovered ? 1 : 0)
                        .frame(width: scale.rowSymbol, height: scale.rowSymbol)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.symbol.tooltip ?? "")
                // A press on the star never starts a row drag (§4.6 "stars").
                .background(reportsStarFrame ? ListElementFrameReporter(kind: .star(row.id)) : nil)
            }
        case .moreButton:
            MoreButtonView(row: row, model: model, isMenuOpen: model.openRowMenuKey == row.id,
                           reportsFrame: reportsStarFrame)
        }
    }
}

/// A row's more button (§4.6 "Archive"; window-design.html `i-more`,
/// `.sym.open`): three dots in the secondary color, always shown, centered
/// in the symbol box, which takes the click. The click opens the row's menu
/// at the button (Core decides) and never selects the row, never counts
/// toward a double-click and never starts a row drag. While the menu is
/// open the box has a pale gray rounded ground.
struct MoreButtonView: View {
    let row: UnifiedListRow
    let model: MainSurfaceModel
    let isMenuOpen: Bool
    /// The list's rows report the box for the drag's press test; the
    /// floating image does not.
    let reportsFrame: Bool
    @State private var anchor: NSView?
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        Button { model.moreButtonClicked(row.id, anchor: anchor) } label: {
            IconShape(icon: .more)
                .fill(SurfaceColors.secondary)
                .frame(width: scale.moreButtonIcon, height: scale.moreButtonIcon)
                .frame(width: scale.rowSymbol, height: scale.rowSymbol)
                .background(
                    RoundedRectangle(cornerRadius: SurfaceMetrics.moreButtonOpenRadius)
                        .fill(isMenuOpen ? SurfaceColors.moreButtonOpenGround : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(RowMoreButton.tooltip)
        .accessibilityLabel(RowMoreButton.accessibilityLabel)
        .background(MenuAnchorView { anchor = $0 })
        .background(reportsFrame ? ListElementFrameReporter(kind: .moreButton(row.id)) : nil)
    }
}

/// The Starred and Recent rows' star, smaller than the status symbol (§4.6 "stars", §9;
/// outline in the secondary color on hover, yellow fill when starred).
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

/// The Refresh icon (`SurfaceIcon.refresh` at the header icon size and line
/// width, in the secondary label color) on a layer of its own: while
/// `spins`, the layer turns clockwise once a second about the icon's
/// center; when it stops, the icon is back at rest.
struct RefreshIconView: NSViewRepresentable {
    let spins: Bool
    let iconSize: CGFloat
    let lineWidth: CGFloat

    func makeNSView(context: Context) -> RefreshIconNSView {
        RefreshIconNSView()
    }

    func updateNSView(_ nsView: RefreshIconNSView, context: Context) {
        nsView.iconSize = iconSize
        nsView.lineWidth = lineWidth
        nsView.spins = spins
    }
}

final class RefreshIconNSView: NSView {
    /// §9: one turn per second.
    static let turnSeconds: CFTimeInterval = 1
    static let animationKey = "cc.shiibar.refresh.spin"
    private let shape = CAShapeLayer()
    /// The icon's side and line width (the header icon's, at the text size).
    var iconSize: CGFloat = 15 {
        didSet { if iconSize != oldValue { updateShapeGeometry() } }
    }
    var lineWidth: CGFloat = 1.4 {
        didSet { if lineWidth != oldValue { updateShapeGeometry() } }
    }

    var spins = false {
        didSet {
            guard spins != oldValue else { return }
            updateSpin()
        }
    }

    /// The icon's path is drawn with y down.
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shape.fillColor = nil
        shape.lineWidth = lineWidth
        shape.lineCap = .round
        shape.lineJoin = .round
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        updateShapeGeometry()
    }

    /// The icon layer at the icon size, centered in the view (the turn is
    /// about its center). Set without implicit animations, so a text size
    /// change does not animate the icon's size.
    private func updateShapeGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        shape.bounds = rect
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shape.path = SurfaceIcon.refresh.path(in: rect).cgPath
        shape.lineWidth = lineWidth
        CATransaction.commit()
    }

    /// The icon layer's bounds and position (for tests).
    var iconLayerBounds: CGRect { shape.bounds }
    var iconLayerPosition: CGPoint { shape.position }

    /// The color resolves for the current light / dark appearance.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shape.strokeColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // An animation does not survive leaving the window.
        updateSpin()
    }

    /// The icon passes clicks to the button around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateSpin() {
        shape.removeAnimation(forKey: Self.animationKey)
        guard spins, window != nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        // In this flipped view a positive angle turns clockwise on screen.
        animation.toValue = 2 * Double.pi
        animation.duration = Self.turnSeconds
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        shape.add(animation, forKey: Self.animationKey)
    }

    /// Whether the turning animation is installed (for tests).
    var isAnimating: Bool { shape.animation(forKey: Self.animationKey) != nil }
}
