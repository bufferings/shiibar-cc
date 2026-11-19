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

/// Header row + list + footer. One column: the footer is the warning rows,
/// the message line and the bottom panel (key hints + the selected row's
/// buttons — §4.6 "bottom panel"). Two columns (the left column): the fixed
/// footer with the key hints only (§4.5 "fixed footer").
struct ListPageView: View {
    @ObservedObject var model: MainSurfaceModel
    let surface: MainSurface
    /// One column with the detail page open: the page stays mounted
    /// underneath it, and its views are no Tab / Shift-Tab targets (§4.5
    /// "key operations").
    let isCoveredByDetailPage: Bool

    var body: some View {
        VStack(spacing: 0) {
            HeaderRowView(model: model, surface: surface, isCoveredByDetailPage: isCoveredByDetailPage)
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
    /// The list page is under the one-column detail page (`ListPageView`).
    let isCoveredByDetailPage: Bool
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
                isKeyViewLoopMember: !isCoveredByDetailPage,
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
                model.refresh()
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
                // §4.5 "pin": OFF = the outline in the secondary color with
                // the other header buttons' hover / press grounds; ON = the
                // accent fill on an accent ground (window-design.html
                // `i-pin`, `.hb.on`).
                Button { model.keepOnTopClicked() } label: {
                    SurfaceIconView(icon: .pin, lineWidth: 1.2, filled: model.keepOnTop)
                        .frame(width: SurfaceMetrics.headerButton, height: SurfaceMetrics.headerButton)
                }
                .buttonStyle(HoverChipButtonStyle(onTint: model.keepOnTop ? Color.accentColor : nil))
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

/// ⟳ (§4.6 / §8.42 / §8.44): runs Refresh (the same as ⌘R). No ground at
/// rest, hover raises a gray ground, press sinks it; in flight the single
/// arrow glyph rotates from upright and settles at a whole turn, and the
/// button is disabled.
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
        .help("Refresh (\u{2318}R)")
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
            VStack(alignment: .leading, spacing: 0) {
                if let empty = list.emptyStateText {
                    Text(empty)
                        .font(.system(size: scale.listNoteFont))
                        .foregroundStyle(SurfaceColors.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, scale.emptyStateVertical)
                }
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    let gap = ListBlockSpacing.gap(before: index, in: blocks, scale: scale)
                    switch block {
                    case .heading(let heading):
                        SectionHeaderView(heading: heading, model: model)
                            .padding(.top, gap)
                    case .frame(let frame):
                        RowFrameView(frame: frame, model: model)
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
                            .padding(.top, gap)
                    }
                }
            }
            .padding(.horizontal, 10)
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
    }
}

/// The vertical space between the list's blocks (window-design.html
/// "collapsing sections and the row drag": spacing between elements). A
/// band (and a heading drawn like one while searching) wants 8 above and 6
/// below; a heading under History 6 above and 4 below; a frame of rows and
/// the `N more` line nothing. Two neighbors are apart by the larger of the
/// upper one's space below and the lower one's space above.
enum ListBlockSpacing {
    static func gap(before index: Int, in blocks: [ListBlock], scale: SurfaceScale) -> CGFloat {
        let top = margins(blocks[index], scale: scale).top
        guard index > 0 else { return top }
        return max(margins(blocks[index - 1], scale: scale).bottom, top)
    }

    private static func margins(_ block: ListBlock, scale: SurfaceScale) -> (top: CGFloat, bottom: CGFloat) {
        switch block {
        case .heading(let heading):
            switch heading.style {
            case .band, .plain: return (scale.sectionHeaderTop, scale.sectionHeaderBottom)
            case .sub: return (scale.subHeadingTop, scale.subHeadingBottom)
            }
        case .frame, .moreLine:
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
              !rows.isEmpty || model.list.visibleRows.isEmpty else { return }
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

/// A heading (§4.5 "the list has three sections" / "collapsing sections" /
/// "row drag"; window-design.html `.rows .sec`): the Running mark, the bold
/// name, the count, the drag's hint, and the chevron at the right end. A
/// band (Running and History) has a gray ground; the headings under History
/// and every heading while searching are text only, with the same padding,
/// so the name and the chevron sit where the band's do. Its edges are the
/// frames' edges, and a click anywhere in that width opens or closes it
/// (Core decides). It has no hover look.
struct SectionHeaderView: View {
    let heading: ListHeadingModel
    let model: MainSurfaceModel
    @Environment(\.surfaceScale) private var scale

    private var ground: Color {
        if heading.isDropTarget { return SurfaceColors.selectionTint }
        return heading.style == .band ? SurfaceColors.sectionBand : .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SurfaceMetrics.sectionBandRadius)
        HStack(alignment: .center, spacing: SurfaceMetrics.sectionBandSpacing) {
            if heading.showsAttentionMark {
                Circle()
                    .fill(SurfaceColors.runningMark)
                    .frame(width: scale.runningMark, height: scale.runningMark)
            }
            Text(heading.title)
                .font(.system(size: scale.sectionTitleFont, weight: .bold))
                .foregroundStyle(heading.isOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(SurfaceColors.secondary))
            if let count = heading.countText {
                Text(count)
                    .font(.system(size: scale.sectionCountFont))
                    .foregroundStyle(SurfaceColors.secondary)
            }
            Spacer(minLength: 0)
            if let hint = heading.hint {
                Text(hint)
                    .font(.system(size: scale.sectionCountFont, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            }
            // While searching the chevron is not shown; its box keeps the
            // heading's height.
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
        .lineLimit(1)
        .padding(.leading, SurfaceMetrics.sectionBandLeading)
        .padding(.trailing, SurfaceMetrics.sectionBandTrailing)
        .padding(.vertical, scale.sectionBandVertical)
        .background(shape.fill(ground))
        .overlay {
            // window-design.html `.sec.over`: the drop target's emphasis.
            if heading.isDropTarget {
                shape.strokeBorder(Color.accentColor, lineWidth: SurfaceMetrics.dropHeaderBorder)
            }
        }
        .contentShape(shape)
        .onTapGesture { model.headingClicked(heading.heading) }
        .background(ListElementFrameReporter(kind: .heading(heading.heading)))
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

    /// The symbol-and-time column (§4.5 "the list has three sections", §9):
    /// the symbol at the top, level with the label line, and the elapsed time
    /// at the bottom, level with the last prompt, both centered in the column.
    /// The elapsed time takes the label's size and color (§4.5) and is never
    /// truncated: when it is wider than the column, the column
    /// widens to fit it and the three lines end earlier.
    private var symbolTimeColumn: some View {
        VStack(spacing: 0) {
            columnSymbol
                .frame(width: scale.rowSymbol, height: scale.rowSymbol)
                .padding(.top, scale.rowSymbolTop)
            Spacer(minLength: 0)
            Text(row.elapsedText)
                .font(.system(size: scale.rowLabelFont))
                .foregroundStyle(SurfaceColors.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(height: scale.rowPromptHeight)
        }
        .frame(minWidth: scale.rowSymbolColumn, maxHeight: .infinity)
    }

    @ViewBuilder
    private var columnSymbol: some View {
        switch row.symbol {
        case .status(let kind, let unreviewed):
            RowSymbolView(kind: kind, unreviewed: unreviewed, spinning: spinning && kind == .working,
                          size: scale.rowSymbol)
        case .star(let isStarred):
            // §4.6: a click on the star toggles it and never selects the row
            // (nor counts toward a double-click). The star is drawn centered
            // in the symbol box, and the whole box reacts to the click (the
            // status symbol's size, §4.6 "stars").
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
