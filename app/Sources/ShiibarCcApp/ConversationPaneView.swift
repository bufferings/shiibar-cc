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

    /// One column (the detail page) vs the two-column right column.
    private var isDetailPage: Bool { pane.showsBackButton }

    var body: some View {
        VStack(spacing: 0) {
            header
            // §4.6: the hairline under the header shows always.
            Rectangle().fill(SurfaceColors.line).frame(height: 1)
            if pane.showsMessages, !model.hits.isEmpty, model.paneLoadError == nil {
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
        HStack(spacing: 8) {
            if isDetailPage && surface == .window {
                Color.clear.frame(width: SurfaceMetrics.trafficLightsWidth - 8, height: 1)
            }
            if pane.showsBackButton {
                Button { model.backClicked() } label: {
                    SurfaceIconView(icon: .back)
                        .frame(width: SurfaceMetrics.headerButton, height: SurfaceMetrics.headerButton)
                }
                .buttonStyle(HoverChipButtonStyle(restingOpacity: 0.10))
                .foregroundStyle(SurfaceColors.secondary)
                .help(ConversationPaneModel.backTooltip)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title)
                    .font(.system(size: isDetailPage ? 13.5 : 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(pane.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(SurfaceColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if pane.showsBackButton {
                if let position = pane.positionText {
                    Text(position)
                        .font(.system(size: 11).monospacedDigit())
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
        .padding(.leading, isDetailPage ? 10 : 16)
        .padding(.trailing, 10)
        .padding(.top, headerTopPadding)
        .padding(.bottom, 8)
        .background(surface == .window ? WindowDragArea() : nil)
    }

    /// `.hdr` 9pt (`.hdr.pad` 11pt in two columns). In the window's detail
    /// page the header shares the traffic lights' vertical center (§4.5).
    private var headerTopPadding: CGFloat {
        if isDetailPage && surface == .window {
            // Title block ≈ 32pt tall, centered on the traffic lights.
            return SurfaceMetrics.windowTrafficLightCenter - 16
        }
        return isDetailPage ? 9 : 11
    }

    // MARK: Find bar (§4.6 "hit navigation")

    /// Two columns: the counter and the ‹ › control, content-sized and
    /// left-aligned. One-column detail page: `Matches for “tag”` at the left
    /// end (no ground, border or icon — it is not an input), the counter and
    /// the control at the right end.
    private var findBar: some View {
        HStack(spacing: 8) {
            if pane.showsQueryInFindBar {
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
            }
            Text(model.hitCounterText ?? "")
                .foregroundStyle(SurfaceColors.secondary)
                .fixedSize()
            FindNavigationControl(
                onPrevious: { model.navigateToOlderHit() },
                onNext: { model.navigateToNewerHit() }
            )
            .fixedSize()
            if !pane.showsQueryInFindBar {
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
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
                }
            } else {
                centeredLine(ConversationPaneModel.noMessagesText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centeredLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(SurfaceColors.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

// MARK: - Bottom panel (§4.6)

/// The warning rows and the message line right above a one-column bottom
/// panel (the list page and the detail page — §4.5 "fixed footer").
struct PanelStatusLinesView: View {
    @ObservedObject var model: MainSurfaceModel

    var body: some View {
        StatusLinesView(model: model)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, model.warnings.isEmpty && model.messageText == nil ? 0 : 7)
    }
}

/// The bottom panel (window-design.html `.actions`): key hints on the left,
/// Branch and the primary button on the right. One view for the one-column
/// list page, the detail page and the two-column right column, so the
/// buttons sit at the same position and size everywhere (§4.6). Without a
/// selection the buttons are replaced by invisible placeholders of the same
/// size: the panel height and the hints' width do not change.
struct BottomPanelView: View {
    @ObservedObject var model: MainSurfaceModel
    let panel: BottomPanelModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(SurfaceColors.line).frame(height: 1)
            HStack(spacing: 10) {
                if panel.hints.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    KeyHintsView(hints: panel.hints)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let buttons = panel.buttons {
                    PanelBranchButton(button: buttons.branch, showsShortcut: panel.showsShortcuts) {
                        model.buttonClicked(buttons.branch)
                    }
                    PanelPrimaryButton(button: buttons.primary, showsShortcut: panel.showsShortcuts) {
                        model.buttonClicked(buttons.primary)
                    }
                } else {
                    Group {
                        PanelBranchButton(button: Self.placeholderBranch) {}
                        PanelPrimaryButton(button: Self.placeholderPrimary) {}
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 10)
        }
    }

    private static let placeholderBranch = RowButton(kind: .branch, invocation: nil, tooltip: "")
    private static let placeholderPrimary = RowButton(kind: .resume, invocation: nil, tooltip: "")
}

/// The detail header's previous / next conversation control (window-design
/// `.seg`: up / down chevrons, disabled at the ends).
private struct ConversationStepper: View {
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(.chevronUp, enabled: canGoPrevious, tooltip: ConversationPaneModel.previousTooltip, action: onPrevious)
            Rectangle().fill(SurfaceColors.line).frame(width: 1, height: 22)
            segment(.chevronDown, enabled: canGoNext, tooltip: ConversationPaneModel.nextTooltip, action: onNext)
        }
        .background(SurfaceColors.chip)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SurfaceColors.line, lineWidth: 1))
    }

    private func segment(_ icon: SurfaceIcon, enabled: Bool, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SurfaceIconView(icon: icon, size: 13, lineWidth: 1.5)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverChipButtonStyle(cornerRadius: 0, isEnabled: enabled))
        .foregroundStyle(SurfaceColors.secondary)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .help(tooltip)
    }
}

/// The find bar's ‹ › control: the native momentary segmented control from
/// the kit (content-sized, per-segment tooltips — §4.6 / §8.38(8)).
private struct FindNavigationControl: NSViewRepresentable {
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
/// window-design.html `.btn .kc`). While the search field has focus the
/// glyph is not drawn but keeps its space, so the button's width and
/// position do not change.
private struct PanelButtonLabel: View {
    let kind: RowButtonKind
    var showsShortcut = true

    var body: some View {
        HStack(spacing: 5) {
            Text(kind.title)
            Text(kind.shortcut)
                .fontWeight(.regular)
                .opacity(showsShortcut ? 0.6 : 0)
                .accessibilityHidden(!showsShortcut)
        }
    }
}

/// The primary panel button (Resume / Jump; `.btn`: accent fill, white
/// 13pt semibold, radius 6, padding 5×14, the same width for both verbs —
/// §4.6 / §8.48). Disabled = the standard gray container (§8.42).
private struct PanelPrimaryButton: View {
    let button: RowButton
    var showsShortcut = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // The wider label reserves the width (Resume and Jump share it).
                PanelButtonLabel(kind: .resume).hidden()
                PanelButtonLabel(kind: button.kind, showsShortcut: showsShortcut)
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(minWidth: 84 - 28)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
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
}

/// Branch (`.btn.sec`: outline only, content-sized, regular weight).
private struct PanelBranchButton: View {
    let button: RowButton
    var showsShortcut = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            PanelButtonLabel(kind: button.kind, showsShortcut: showsShortcut)
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .foregroundStyle(button.isEnabled ? Color.primary : Color.gray.opacity(0.75))
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering && button.isEnabled ? Color.gray.opacity(0.12) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SurfaceColors.line, lineWidth: 1))
        }
        .buttonStyle(PressDimButtonStyle(hovering: false))
        .onHover { hovering = $0 }
        .disabled(!button.isEnabled)
        .help(button.tooltip)
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
