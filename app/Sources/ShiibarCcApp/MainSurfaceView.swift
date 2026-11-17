// The single layout shown by both the popover and the window (DESIGN.md
// §4.5 "switching by width", §8.49; docs/window-design.html). One column:
// the list page and the detail page, one at a time — the detail page slides
// in from the trailing edge and slides back out (§9 duration). Two columns
// (window only, from §9's width): the list column on the left — at the
// width remembered from a boundary drag, else at a width that follows the
// text size — and the conversation pane on the right. The
// column mode and the page come from the shared `UnifiedListState`; the
// window reports its width class to the model. Both roots hand the text
// size's ratio to every view below through `\.surfaceScale` (DESIGN.md
// §4.5 "text size").

import AppKit
import ShiibarCcCore
import SwiftUI

struct MainSurfaceView: View {
    @ObservedObject var model: MainSurfaceModel
    @ObservedObject var textSize: TextSizeStore
    let surface: MainSurface

    var body: some View {
        GeometryReader { geometry in
            content(width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onAppear { reportWidth(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in reportWidth(width) }
        }
        .ignoresSafeArea()
        .environment(\.surfaceScale, scale)
    }

    private func reportWidth(_ width: CGFloat) {
        guard surface == .window else { return }
        // The model decides the column mode; it decides again when the text
        // size moves the threshold (§9).
        model.windowWidthChanged(Double(width))
    }

    /// The popover always shows one column; the window follows the shared
    /// state (which tracks its width while it is the visible surface).
    private var columns: ColumnMode {
        surface == .popover ? .one : model.list.columns
    }

    private var listBackground: Color { SurfaceColors.listBackground }

    private var paneBackground: Color { SurfaceColors.paneBackground }

    /// This view sets the environment value, so it computes its own copy.
    private var scale: SurfaceScale { SurfaceScale(ratio: CGFloat(textSize.size.ratio)) }

    /// One layout for both column modes, so the list page keeps one view
    /// identity when the column count changes (§4.5 "when the width
    /// changes": the key target stays). A list page built anew would bring a
    /// new search field, and a new field honors the surface's latest focus
    /// request on its first update (`ConversationsSearchField`), which would
    /// move the focus to it; the list's scroll position also stays.
    private func content(width: CGFloat) -> some View {
        // One column: the list page stays mounted underneath (its scroll
        // position and search field survive), the detail page slides over it.
        let detailPane: ConversationPaneModel? = {
            guard columns == .one, model.list.columns == .one,
                  case .conversation(let pane) = model.list.paneContent else { return nil }
            return pane
        }()
        return SurfaceColumns(
            columnWidth: model.listColumnWidth,
            columns: columns,
            textSize: textSize.size,
            windowWidth: width,
            listPage: {
                ListPageView(model: model, surface: surface, isCoveredByDetailPage: detailPane != nil)
                    .background(listBackground)
                    .allowsHitTesting(detailPane == nil)
                    .accessibilityHidden(detailPane != nil)
            },
            rightColumn: {
                rightColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(paneBackground)
            },
            detailPage: {
                if let detailPane {
                    ConversationPaneView(model: model, pane: detailPane, surface: surface)
                        .background(paneBackground)
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                }
            }
        )
        .clipped()
        // Only the one-column page change slides; leaving one column (the
        // detail page closes at the same time) switches without animation.
        .animation(
            columns == .one ? .easeInOut(duration: MainWindowMetrics.pageSlideSeconds) : nil,
            value: detailPane != nil)
    }

    @ViewBuilder
    private var rightColumn: some View {
        switch model.list.paneContent {
        case .conversation(let pane):
            ConversationPaneView(model: model, pane: pane, surface: surface)
        case .noSelection, .hidden:
            // §4.5: two columns without a selection — only the centered line.
            Text(ConversationPaneContent.noSelectionText)
                .font(.system(size: scale.centeredLineFont))
                .foregroundStyle(SurfaceColors.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

/// The columns of the surface (§4.5). One column: the list page at the full
/// width, with the detail page (when open) over it. Two columns: the list
/// column, the 1pt boundary line, and the pane; the boundary's drag area
/// lies over both columns. The list page sits at the same place in the view
/// tree in both modes, so it keeps its identity — its search field, focus,
/// scroll position and selection — when the column count or its width
/// changes. Only this view observes the column width, so a drag re-lays out
/// the columns without re-evaluating the rest of the surface.
private struct SurfaceColumns<ListPage: View, RightColumn: View, DetailPage: View>: View {
    @ObservedObject var columnWidth: ListColumnWidthStore
    let columns: ColumnMode
    let textSize: TextSize
    let windowWidth: CGFloat
    @ViewBuilder let listPage: ListPage
    @ViewBuilder let rightColumn: RightColumn
    @ViewBuilder let detailPage: DetailPage

    var body: some View {
        let twoColumns = columns == .two
        let listWidth = twoColumns
            ? CGFloat(columnWidth.shownWidth(windowWidth: Double(windowWidth), textSize: textSize))
            : windowWidth
        ZStack {
            HStack(spacing: 0) {
                listPage
                    .frame(width: listWidth)
                if twoColumns {
                    Rectangle().fill(SurfaceColors.line).frame(width: 1)
                    rightColumn
                }
            }
            // §4.5 / §9: the drag area is centered on the boundary line (4pt
            // on each side of its center) and sits above both columns, so it
            // takes the mouse before the list, the pane, or the header row's
            // window drag. Outside its 8pt nothing is covered: the leading
            // padding has no content and is not hit-tested.
            .overlay(alignment: .topLeading) {
                if twoColumns {
                    ColumnBoundaryDragArea(
                        onBegin: { columnWidth.beginDrag(windowWidth: Double(windowWidth), textSize: textSize) },
                        onDrag: { delta in columnWidth.updateDrag(delta: delta, windowWidth: Double(windowWidth)) },
                        onEnd: { columnWidth.endDrag() },
                        onCancel: { columnWidth.cancelDrag() },
                        onDoubleClick: { columnWidth.resetToDefault() }
                    )
                    .frame(width: CGFloat(ListColumnWidth.dragAreaWidth))
                    .frame(maxHeight: .infinity)
                    .padding(.leading, listWidth + 0.5 - CGFloat(ListColumnWidth.dragAreaWidth) / 2)
                }
            }
            detailPage
        }
    }
}

/// Hosts the AppKit view that tracks the boundary drag (cursor, screen-
/// coordinate travel, double click). The callbacks are refreshed on every
/// update, so they read the current window width and text size.
private struct ColumnBoundaryDragArea: NSViewRepresentable {
    let onBegin: () -> Void
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ColumnBoundaryDragView {
        let view = ColumnBoundaryDragView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: ColumnBoundaryDragView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: ColumnBoundaryDragView) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onCancel = onCancel
        view.onDoubleClick = onDoubleClick
    }
}

/// The column boundary's drag area (§4.5 "column boundary drag", §9):
/// nothing drawn, a left-right resize cursor. A single press starts a drag
/// whose travel is read in screen coordinates (the view itself moves with
/// the boundary, so its own coordinates would drift); a double click resets
/// the width instead. It never lets a press move the window.
final class ColumnBoundaryDragView: NSView {
    var onBegin: () -> Void = {}
    var onDrag: (Double) -> Void = { _ in }
    var onEnd: () -> Void = {}
    var onCancel: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    /// The screen location of the pointer; injected for tests.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var startX: CGFloat = 0
    private(set) var isDragging = false

    /// A transparent view moves the window by default in a window with a
    /// hidden title bar; the boundary press must start the resize instead.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            isDragging = false
            onDoubleClick()
            return
        }
        isDragging = true
        startX = pointerLocation().x
        onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        // The pointer can leave the 8pt area while the width is held at an
        // end of the range; the cursor stays the resize one until mouse-up.
        NSCursor.resizeLeftRight.set()
        onDrag(Double(pointerLocation().x - startX))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onEnd()
    }

    /// Leaving the window while the mouse is held (the window closes) means
    /// no mouse-up arrives here: the drag ends without remembering the width.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, isDragging else { return }
        isDragging = false
        onCancel()
    }
}
