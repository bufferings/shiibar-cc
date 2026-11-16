// The single layout shown by both the popover and the window (DESIGN.md
// §4.5 "switching by width", §8.49; docs/window-design.html). One column:
// the list page and the detail page, one at a time — the detail page slides
// in from the trailing edge and slides back out (§9 duration). Two columns
// (window only, from §9's width): the list column at a fixed width on the
// left and the conversation pane on the right. The column mode and the
// page come from the shared `UnifiedListState`; the window reports its
// width class to the model.

import AppKit
import ShiibarCcCore
import SwiftUI

struct MainSurfaceView: View {
    @ObservedObject var model: MainSurfaceModel
    let surface: MainSurface

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onAppear { reportWidth(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in reportWidth(width) }
        }
        .ignoresSafeArea()
    }

    private func reportWidth(_ width: CGFloat) {
        guard surface == .window else { return }
        model.windowColumnsChanged(ColumnMode.forWindowWidth(Double(width)))
    }

    /// The popover always shows one column; the window follows the shared
    /// state (which tracks its width while it is the visible surface).
    private var columns: ColumnMode {
        surface == .popover ? .one : model.list.columns
    }

    private var listBackground: Color { SurfaceColors.listBackground }

    private var paneBackground: Color { SurfaceColors.paneBackground }

    @ViewBuilder
    private var content: some View {
        if columns == .two {
            HStack(spacing: 0) {
                ListPageView(model: model, surface: surface)
                    .frame(width: CGFloat(MainWindowMetrics.listColumnWidth))
                    .background(listBackground)
                Rectangle().fill(SurfaceColors.line).frame(width: 1)
                rightColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(paneBackground)
            }
        } else {
            oneColumn
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        switch model.list.paneContent {
        case .conversation(let pane):
            ConversationPaneView(model: model, pane: pane, surface: surface)
        case .noSelection, .hidden:
            // §4.5: two columns without a selection — only the centered line.
            Text(ConversationPaneContent.noSelectionText)
                .font(.system(size: 12))
                .foregroundStyle(SurfaceColors.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One column: the list page stays mounted underneath (its scroll
    /// position and search field survive), the detail page slides over it.
    private var oneColumn: some View {
        let detailPane: ConversationPaneModel? = {
            guard model.list.columns == .one,
                  case .conversation(let pane) = model.list.paneContent else { return nil }
            return pane
        }()
        return ZStack {
            ListPageView(model: model, surface: surface)
                .background(listBackground)
                .allowsHitTesting(detailPane == nil)
                .accessibilityHidden(detailPane != nil)
            if let detailPane {
                ConversationPaneView(model: model, pane: detailPane, surface: surface)
                    .background(paneBackground)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: MainWindowMetrics.pageSlideSeconds), value: detailPane != nil)
    }
}
