// The conversation pane (DESIGN.md §4.6 "conversation pane", §4.5 "row
// click" / "switching by width"; visual spec: docs/window-design.html
// "detail page", "two columns", "bottom panel states"): header, find bar,
// the message surface (the shared WKWebView page), and the bottom panel.
// The bottom panel view is shared with the one-column list page (§4.6
// "bottom panel"). Everything shown comes from `ConversationPaneModel` /
// `BottomPanelModel` (Core) and the model's hits; this file only lays it
// out.

import AppKit
import ConversationsWebPaneKit
import ShiibarCcCore
import SwiftUI
import WebKit

struct ConversationPaneView: View {
    @ObservedObject var model: MainSurfaceModel
    let pane: ConversationPaneModel
    let surface: MainSurface
    @Environment(\.surfaceScale) private var scale

    /// One column (the detail page) vs the two-column right column.
    private var isDetailPage: Bool { pane.showsBackButton }

    var body: some View {
        VStack(spacing: 0) {
            header
            // §4.6: the hairline under the header shows always.
            Rectangle().fill(SurfaceColors.line).frame(height: 1)
            // Two columns: the counter and ‹ › sit in the window-wide header
            // row instead (`HeaderRowLayout`).
            if isDetailPage, pane.showsMessages, !model.hits.isEmpty, model.paneLoadError == nil {
                findBar
                Rectangle().fill(SurfaceColors.line).frame(height: 1)
            }
            messageSurface
            if isDetailPage {
                // §4.5: in the one-column detail page the warning rows and
                // the message line sit right above the bottom panel.
                PanelStatusLinesView(model: model)
            }
            BottomPanelView(model: model, panel: pane.bottomPanel)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: SurfaceMetrics.headerSpacing) {
            // The traffic lights' place; in full screen there are none there.
            if isDetailPage && surface == .window && !model.isFullScreen(surface) {
                Color.clear.frame(width: SurfaceMetrics.trafficLightsWidth - SurfaceMetrics.headerSpacing, height: 1)
            }
            if pane.showsBackButton {
                Button { model.backClicked() } label: {
                    SurfaceIconView(icon: .back, size: scale.headerIcon, lineWidth: scale.headerIconLine)
                        .frame(width: scale.headerButton, height: scale.headerButton)
                }
                .buttonStyle(HoverChipButtonStyle(restingOpacity: 0.10))
                .foregroundStyle(SurfaceColors.secondary)
                .help(ConversationPaneModel.backTooltip)
            }
            // §4.6: the label line above the title, in the order of the list
            // row's label and title (§4.5).
            VStack(alignment: .leading, spacing: scale.paneTitleSpacing) {
                Text(pane.labelAndElapsed)
                    .font(.system(size: scale.paneLabelFont))
                    .foregroundStyle(SurfaceColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pane.title)
                    .font(.system(size: isDetailPage ? scale.paneTitleDetailFont : scale.paneTitleColumnFont,
                                  weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if pane.showsBackButton {
                if let position = pane.positionText {
                    Text(position)
                        .font(.system(size: scale.panePositionFont).monospacedDigit())
                        .foregroundStyle(SurfaceColors.secondary)
                }
                ConversationStepper(
                    canGoPrevious: pane.canGoPrevious,
                    canGoNext: pane.canGoNext,
                    onPrevious: { model.previousConversationClicked() },
                    onNext: { model.nextConversationClicked() }
                )
            }
        }
        // The window's detail page: the row is at least its nominal height,
        // so the equal space above and below centers it on the traffic
        // lights.
        .frame(minHeight: isWindowDetailPage ? scale.windowDetailPaneHeaderRowHeight : nil)
        .padding(.leading, isDetailPage ? 10 : 16)
        .padding(.trailing, 10)
        .padding(.top, headerTopPadding)
        .padding(.bottom, headerBottomPadding)
        // Only the window's detail page has no header row above it, so its
        // pane header is the place to drag the window; in two columns the
        // window-wide header row is.
        .background(surface == .window && isDetailPage ? WindowDragArea() : nil)
    }

    private var isWindowDetailPage: Bool { surface == .window && isDetailPage }

    /// `.hdr` 9pt (`.hdr.pad` 11pt in two columns) at text size 13. The
    /// window's detail page follows the window header rule: its row on the
    /// traffic lights with equal space above and below (§4.5 "header
    /// row"); in two columns the header sits under the window-wide header
    /// row.
    private var headerTopPadding: CGFloat {
        if isWindowDetailPage {
            return scale.windowDetailPaneHeaderPadding
        }
        return isDetailPage ? scale.paneHeaderTopDetail : scale.paneHeaderTopColumn
    }

    private var headerBottomPadding: CGFloat {
        isWindowDetailPage ? scale.windowDetailPaneHeaderPadding : scale.paneHeaderBottom
    }

    // MARK: Find bar (§4.6 "hit navigation")

    /// One-column detail page only: `Matches for “tag”` at the left end (no
    /// ground, border or icon — it is not an input), the counter and the
    /// control at the right end.
    private var findBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(FindBarQueryText.prefix)
                    .foregroundStyle(SurfaceColors.secondary)
                    .fixedSize()
                Text(FindBarQueryText.quotedTerm(model.query))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
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
        .padding(.horizontal, 16)
        .padding(.vertical, scale.findBarVertical)
    }

    // MARK: Message surface

    @ViewBuilder
    private var messageSurface: some View {
        ZStack {
            if pane.showsMessages {
                SharedWebPaneHost(
                    controller: model.webPane,
                    attachToken: model.paneAttachRequest,
                    focusToken: model.paneFocusRequests[surface] ?? 0
                )
                if let error = model.paneLoadError {
                    centeredLine(error)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(surface == .window ? SurfaceColors.paneBackground : Color(nsColor: .windowBackgroundColor))
                } else if model.paneShowsNoConversation {
                    // §4.6: a Running row's conversation the index does not
                    // have yet (no message sent) — the same line as a row
                    // without a session_id.
                    centeredLine(ConversationPaneModel.noMessagesText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(surface == .window ? SurfaceColors.paneBackground : Color(nsColor: .windowBackgroundColor))
                }
            } else {
                centeredLine(ConversationPaneModel.noMessagesText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centeredLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: scale.centeredLineFont))
            .foregroundStyle(SurfaceColors.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

// MARK: - Bottom panel (§4.6)

/// The warning rows and the message line right above a one-column bottom
/// panel (the list page and the detail page — §4.5 "fixed footer").
struct PanelStatusLinesView: View {
    @ObservedObject var model: MainSurfaceModel
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        StatusLinesView(model: model)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, model.warnings.isEmpty && model.messageText == nil ? 0 : scale.panelStatusBottom)
    }
}

/// The bottom panel (window-design.html `.actions`): key hints on the left,
/// the buttons on the right — View (one-column list page only), Branch and
/// the primary button, in `panel.slots` order. One view for the one-column
/// list page, the detail page and the two-column right column, so Branch and
/// the primary button sit at the same position and size everywhere (§4.6). While the
/// buttons are not shown (no selection, or the search field has focus) they
/// are replaced by invisible placeholders of the same size: the panel height
/// and the hints' width do not change. When the width runs short the
/// buttons keep their size and the hints take what is left (§4.5 "text
/// size"). When a shown button is disabled, its reason
/// (`panel.disabledReasons`, one line per distinct reason) sits on its own
/// line above the button row, right-aligned with the buttons: the button row
/// cannot fit the text next to the three buttons at the popover width. The
/// panel grows by those lines while they are shown; the button row and its
/// distance from the panel's bottom edge stay the same.
struct BottomPanelView: View {
    @ObservedObject var model: MainSurfaceModel
    let panel: BottomPanelModel
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        let reasons = panel.disabledReasons
        VStack(spacing: 0) {
            Rectangle().fill(SurfaceColors.line).frame(height: 1)
            if !reasons.isEmpty {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(reasons, id: \.self) { reason in
                        // The full panel width is available, so truncation
                        // is a last resort for a very narrow surface.
                        Text(reason)
                            .font(.system(size: scale.keyLabelFont))
                            .foregroundStyle(SurfaceColors.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.top, scale.panelTop)
            }
            HStack(spacing: 10) {
                if panel.hints.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    KeyHintsView(hints: panel.hints)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Group {
                    if let buttons = panel.buttons {
                        slotButtons(buttons)
                    } else {
                        slotButtons(Self.placeholders)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                }
                .fixedSize()
                .layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, reasons.isEmpty ? scale.panelTop : scale.panelReasonBottom)
            .padding(.bottom, scale.panelBottom)
        }
    }

    @ViewBuilder
    private func slotButtons(_ buttons: BottomPanelButtons) -> some View {
        ForEach(panel.slots, id: \.self) { slot in
            switch slot {
            case .view:
                PanelSecondaryButton(
                    title: BottomPanelModel.viewTitle, shortcut: BottomPanelModel.viewShortcut,
                    isEnabled: true, tooltip: nil
                ) { model.viewClicked() }
            case .branch:
                PanelSecondaryButton(
                    title: buttons.branch.kind.title, shortcut: buttons.branch.kind.shortcut,
                    isEnabled: buttons.branch.isEnabled, tooltip: buttons.branch.tooltip
                ) { model.buttonClicked(buttons.branch) }
            case .primary:
                PanelPrimaryButton(button: buttons.primary) {
                    model.buttonClicked(buttons.primary)
                }
            }
        }
    }

    private static let placeholders = BottomPanelButtons(
        primary: RowButton(kind: .resume, invocation: nil, tooltip: ""),
        branch: RowButton(kind: .branch, invocation: nil, tooltip: ""))
}

/// The detail header's previous / next conversation control (window-design
/// `.seg`: up / down chevrons, disabled at the ends).
private struct ConversationStepper: View {
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            segment(.chevronUp, enabled: canGoPrevious, tooltip: ConversationPaneModel.previousTooltip, action: onPrevious)
            Rectangle().fill(SurfaceColors.line).frame(width: 1, height: scale.stepperSegmentHeight)
            segment(.chevronDown, enabled: canGoNext, tooltip: ConversationPaneModel.nextTooltip, action: onNext)
        }
        .background(SurfaceColors.chip)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SurfaceColors.line, lineWidth: 1))
    }

    private func segment(_ icon: SurfaceIcon, enabled: Bool, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SurfaceIconView(icon: icon, size: scale.stepperIcon, lineWidth: scale.stepperIconLine)
                .frame(width: scale.stepperSegmentWidth, height: scale.stepperSegmentHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverChipButtonStyle(cornerRadius: 0, isEnabled: enabled))
        .foregroundStyle(SurfaceColors.secondary)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .help(tooltip)
    }
}

/// The hit navigation's ‹ › control (the one-column find bar and the
/// two-column header row): the native momentary segmented control from the
/// kit (content-sized, per-segment tooltips — §4.6 / §8.38(8)).
struct FindNavigationControl: NSViewRepresentable {
    let onPrevious: () -> Void
    let onNext: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrevious: onPrevious, onNext: onNext)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        FindBarControls.makeSegmentedControl(
            target: context.coordinator,
            action: #selector(Coordinator.segmentActivated(_:))
        )
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.onPrevious = onPrevious
        context.coordinator.onNext = onNext
    }

    final class Coordinator: NSObject {
        var onPrevious: () -> Void
        var onNext: () -> Void

        init(onPrevious: @escaping () -> Void, onNext: @escaping () -> Void) {
            self.onPrevious = onPrevious
            self.onNext = onNext
        }

        @objc func segmentActivated(_ sender: NSSegmentedControl) {
            sender.selectedSegment == 0 ? onPrevious() : onNext()
        }
    }
}

/// A panel button's label: the title, then its shortcut glyph, dimmer
/// than the title and shown also while disabled (§4.6 "bottom panel";
/// window-design.html `.btn .kc`).
private struct PanelButtonLabel: View {
    let title: String
    let shortcut: String

    init(title: String, shortcut: String) {
        self.title = title
        self.shortcut = shortcut
    }

    init(kind: RowButtonKind) {
        self.init(title: kind.title, shortcut: kind.shortcut)
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Text(shortcut)
                .fontWeight(.regular)
                .opacity(0.6)
        }
    }
}

/// The primary panel button (Resume / Jump; `.btn`: accent fill, white
/// 13pt semibold, radius 6, padding 5×14, the same width for both verbs —
/// §4.6 / §8.48). Disabled = the standard gray container (§8.42).
private struct PanelPrimaryButton: View {
    let button: RowButton
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        Button(action: action) {
            ZStack {
                // The wider label reserves the width (Resume and Jump share it).
                PanelButtonLabel(kind: .resume).hidden()
                PanelButtonLabel(kind: button.kind)
            }
            .font(.system(size: scale.panelButtonFont, weight: .semibold))
            .frame(minWidth: scale.primaryButtonMinWidth - 2 * Self.horizontalPadding)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, scale.primaryButtonVertical)
            .foregroundStyle(button.isEnabled ? Color.white : Color.gray.opacity(0.75))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(button.isEnabled ? Color.accentColor : Color.gray.opacity(0.18))
            )
        }
        .buttonStyle(PressDimButtonStyle(hovering: hovering && button.isEnabled))
        .onHover { hovering = $0 }
        .disabled(!button.isEnabled)
        .help(button.tooltip)
    }

    /// `.btn` horizontal padding (fixed; the minimum width includes it).
    private static let horizontalPadding: CGFloat = 14
}

/// A secondary panel button — View and Branch (`.btn.sec`: outline only,
/// content-sized, regular weight).
private struct PanelSecondaryButton: View {
    let title: String
    let shortcut: String
    let isEnabled: Bool
    /// nil = no tooltip (View: §4.6 names none).
    let tooltip: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.surfaceScale) private var scale

    var body: some View {
        let button = Button(action: action) {
            PanelButtonLabel(title: title, shortcut: shortcut)
                .font(.system(size: scale.panelButtonFont))
                .padding(.horizontal, 14)
                .padding(.vertical, scale.branchButtonVertical)
                .foregroundStyle(isEnabled ? Color.primary : Color.gray.opacity(0.75))
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering && isEnabled ? Color.gray.opacity(0.12) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SurfaceColors.line, lineWidth: 1))
        }
        .buttonStyle(PressDimButtonStyle(hovering: false))
        .onHover { hovering = $0 }
        .disabled(!isEnabled)
        if let tooltip {
            button.help(tooltip)
        } else {
            button
        }
    }
}

private struct PressDimButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.12 : (hovering ? -0.06 : 0))
            .contentShape(Rectangle())
    }
}

// MARK: - Shared web view host

/// Hosts the ONE `WebPaneController.webView` (§4.6 rendering engine). The
/// popover and the window each have their own host; the web view moves to
/// whichever host is on screen — when a host enters a window, and when the
/// model asks the visible surface to re-attach (`attachToken`).
struct SharedWebPaneHost: NSViewRepresentable {
    let controller: WebPaneController
    let attachToken: Int
    let focusToken: Int
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.webView = controller.webView
        controller.setDarkTheme(colorScheme == .dark)
        context.coordinator.lastAttachToken = attachToken
        // `lastFocusToken` stays 0 so a request issued before this host
        // existed is honored by the first update.
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.webView = controller.webView
        controller.setDarkTheme(colorScheme == .dark)
        if context.coordinator.lastAttachToken != attachToken {
            context.coordinator.lastAttachToken = attachToken
            DispatchQueue.main.async { view.adoptIfVisible() }
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                view.adoptIfVisible()
                guard let window = view.window, window.isVisible, let webView = view.webView,
                      webView.superview === view else { return }
                window.makeFirstResponder(webView)
            }
        }
    }

    final class Coordinator {
        var lastAttachToken = 0
        var lastFocusToken = 0
    }

    final class HostView: NSView {
        weak var webView: WKWebView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            adoptIfVisible()
        }

        /// Take the web view when this host is in a visible window (or in a
        /// window at all when nothing else holds it).
        func adoptIfVisible() {
            guard let webView, let window else { return }
            let holderVisible = webView.window?.isVisible ?? false
            guard window.isVisible || !holderVisible || webView.superview == nil else { return }
            guard webView.superview !== self else { return }
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
    }
}
