// Conversations window UI (DESIGN.md §4.6; visual spec:
// docs/conversations-design.html). Two-pane master/detail with a full-height
// sidebar: left = search + list + status line on sidebar material that
// reaches the window top (the traffic lights sit over it), right = the
// selected conversation on the normal window background — the reading
// surface (§8.35). The message flow itself renders in the bundled page
// (WKWebView — §4.6 rendering engine, §8.38, ConversationsWebPaneKit);
// header, find bar, and Resume stay native. All decisions (query rules,
// block splitting, hit offsets, fold boundary) live in
// `ConversationsViewModel` / ShiibarCcCore; this file is presentation only.
// UI strings are English; conversation content (titles, message text) is
// user data shown verbatim.

import AppKit
import ConversationsWebPaneKit
import ShiibarCcCore
import SwiftUI

struct ConversationsContentView: View {
    @ObservedObject var viewModel: ConversationsViewModel
    /// Shared body-size store (§4.6/§4.5): observed here so cmd shortcuts
    /// and the Settings stepper re-render the right pane immediately.
    @ObservedObject var textSize: ConversationsTextSizeStore

    /// Sidebar width (§9: initial 250pt, drag-clamped 200-400pt, remembered
    /// in UserDefaults — the same discipline as the window frame autosave).
    @AppStorage("cc.shiibar.conversationsSidebarWidth")
    private var sidebarWidth: Double = ConversationsConstants.sidebarInitialWidth
    /// The width when the current divider drag began.
    @State private var dragStartWidth: Double?
    /// The pointer is over the divider grab strip (§8.38(8): the line
    /// strengthens as the affordance).
    @State private var dividerHovered = false

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: ConversationsConstants.clampSidebarWidth(sidebarWidth))
                .background(
                    // Full-height sidebar (§4.6/§8.35): sidebar material up
                    // to the window top — `.ignoresSafeArea` extends it under
                    // the hidden-title-bar traffic-light band — with a 1pt
                    // separator against the reading pane. The material is
                    // bound to the pane frame, so it stays correct while the
                    // divider drags.
                    SidebarBackgroundView()
                        .overlay(alignment: .trailing) {
                            Color(nsColor: dividerHovered ? .tertiaryLabelColor : .separatorColor)
                                .frame(width: dividerHovered ? 2 : 1)
                        }
                        .ignoresSafeArea()
                )
                .overlay(alignment: .trailing) { sidebarDragHandle }
            rightPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// An invisible 9pt grab strip straddling the sidebar boundary
    /// (§8.38(7)(8): the divider drags; the fixed width became the initial
    /// value). The resize cursor comes from AppKit cursor rects — SwiftUI's
    /// onHover + NSCursor.push proved unreliable on-device — and the same
    /// tracking area drives the stronger divider line while hovered.
    private var sidebarDragHandle: some View {
        ResizeCursorStrip(onHoverChanged: { dividerHovered = $0 })
            .frame(width: 9)
            .contentShape(Rectangle())
            .offset(x: 4)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = sidebarWidth }
                        sidebarWidth = ConversationsConstants.clampSidebarWidth(
                            (dragStartWidth ?? sidebarWidth) + value.translation.width
                        )
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
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
            // IME-aware NSSearchField (§4.6/§8.38(12)): no dispatch while
            // marked text is active, guaranteed dispatch on commit, and the
            // ⌘F focus target (§8.41). Its native rounded style matches the
            // mock's search box.
            ConversationsSearchField(
                text: $viewModel.query,
                isEnabled: !viewModel.searchDisabled,
                focusToken: viewModel.searchFocusToken
            )
            .onChange(of: viewModel.query) {
                // List search is debounced (§9); preview highlights
                // recompute instantly and never move the scroll.
                viewModel.queryChanged()
                viewModel.queryChangedForPreview()
            }

            RefreshButton(startTime: viewModel.refreshStartedAt, runEndTime: viewModel.refreshRunEndedAt) {
                viewModel.refreshTapped()
            }
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

/// The find bar's back/forward control: a native momentary
/// NSSegmentedControl (§4.6 — the standard find-bar look SwiftUI has no
/// built-in equivalent for), with per-segment tooltips.
private struct FindNavigationControl: NSViewRepresentable {
    let onPrevious: () -> Void
    let onNext: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrevious: onPrevious, onNext: onNext)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        // Sizing behavior lives in the kit factory, pinned by a test
        // (§8.38(8): it stretched across the pane in the owner's build).
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

/// The ⟳ button (§4.6/§8.42/§8.44 — feedback comes first from the operated
/// control): hover raises the background, press sinks it, and in flight the
/// single arrow GLYPH rotates continuously (deliberately NOT the
/// glyph-cycling working spinner, which §4.5 reserves for agent status)
/// while the button is disabled. Idle shows NO background so a static gray
/// pill uniquely means "disabled" (§8.44). `startTime` is non-nil for
/// exactly as long as the button spins; `runEndTime` is when the run's
/// result landed (nil while still in flight).
private struct RefreshButton: View {
    let startTime: Date?
    let runEndTime: Date?
    let action: () -> Void
    @State private var hovering = false

    private var inFlight: Bool { startTime != nil }

    var body: some View {
        Button(action: action) {
            Group {
                if let startTime {
                    // The rotation exists ONLY in this branch, and its phase
                    // is anchored to `startTime` (not wall-clock), so it
                    // always begins upright (0°) and the switch to the static
                    // glyph lands at a whole-turn boundary — angle zero, no
                    // visible jump (§4.6/§8.44). (A .repeatForever animation
                    // is NOT cancelled by a plain property write — the
                    // round-9 spinner never stopped on-device; a TimelineView
                    // phase was probe-proven to animate and to settle
                    // bit-identically to the idle frame — §8.42/§8.43.)
                    TimelineView(.animation) { context in
                        let elapsed = context.date.timeIntervalSince(startTime)
                        let runEnd = runEndTime.map { $0.timeIntervalSince(startTime) }
                        let angle = ConversationsRefreshSpin.isSpinning(
                            elapsedSeconds: elapsed, runEndSeconds: runEnd
                        ) ? ConversationsRefreshSpin.angleDegrees(elapsedSeconds: elapsed) : 0
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .rotationEffect(.degrees(angle))
                    }
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(RefreshButtonStyle(hovering: hovering, inFlight: inFlight))
        .disabled(inFlight)
        .onHover { hovering = $0 }
        .help("Refresh")
    }
}

/// Idle / in-flight: no ground. Hover 0.20 (raised) / press 0.26 (sunken) —
/// the same translucent-gray family as the list-row hover. Idle stays clear
/// so a constant gray pill uniquely reads as "disabled" (§8.42/§8.44).
private struct RefreshButtonStyle: ButtonStyle {
    let hovering: Bool
    let inFlight: Bool

    func makeBody(configuration: Configuration) -> some View {
        let opacity: Double
        if configuration.isPressed {
            opacity = 0.26 // sunken
        } else if hovering && !inFlight {
            opacity = 0.20 // raised
        } else {
            opacity = 0 // idle / in-flight: no ground (§8.44)
        }
        return configuration.label
            .background(Color.gray.opacity(opacity))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// The enabled Resume verb at the mock's exact .btn metrics (§8.39
/// normative CSS: 13px semibold, padding 5px 18px, radius 6, accent fill,
/// white text) — .controlSize approximations read the wrong size
/// on-device. Hover darkens slightly; press darkens more (§8.42).
private struct ResumeButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button("Resume", action: action)
            .buttonStyle(ResumeButtonStyle(hovering: hovering))
            .onHover { hovering = $0 }
    }
}

private struct ResumeButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 5)
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlAccentColor)))
            .brightness(configuration.isPressed ? -0.12 : (hovering ? -0.06 : 0))
    }
}

/// The sidebar divider's cursor/hover surface: AppKit cursor rects (the
/// reliable mechanism — resetCursorRects re-registers on geometry changes)
/// plus a tracking area for the hover callback. hitTest returns nil so the
/// SwiftUI drag gesture on the strip keeps receiving the clicks.
private struct ResizeCursorStrip: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> StripView {
        let view = StripView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: StripView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }

    final class StripView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
        override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

        /// Transparent to clicks: cursor rects and tracking areas work by
        /// registered rects, not hit testing, so the SwiftUI gesture wins.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
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
            // §4.6/§8.38(8): the hairline under the header shows ALWAYS,
            // find bar or not.
            Divider()
            if !viewModel.hits.isEmpty {
                findBar
                Divider()
            }
            chat
            actionPanel
        }
    }

    /// The bottom panel keeps a constant presence and height for every
    /// selected conversation (§4.6/§8.38(8)): a live row shows Resume
    /// disabled with a faint note instead of dropping the panel.
    private var actionPanel: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Spacer()
                // §4.6 (f970e29): the note clusters immediately LEFT OF THE
                // BUTTON — not at the panel's left edge.
                if summary?.live == true {
                    Text("This conversation is running")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // §4.6/§8.42: the disabled state (running rows) wears the
                // STANDARD gray container — never the washed prominent
                // blue; the enabled verb stays prominent at the mock's .btn
                // size (§8.39) and reacts to hover (press is built into the
                // prominent style).
                if summary.map(viewModel.canResume) ?? false {
                    ResumeButton {
                        if let summary { viewModel.resume(summary) }
                    }
                } else {
                    // The disabled twin shares the enabled button's exact
                    // metrics (constant panel height), in the standard gray.
                    Text("Resume")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 18)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.16)))
                }
            }
            .padding(12)
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

    // §4.6/§8.38(7): the macOS standard in-document find grammar — an
    // "N of M" counter and a momentary back/forward segmented control.
    // Next (the right segment, ⌘G) = newer; Previous (left, ⇧⌘G) = older.
    private var findBar: some View {
        HStack(spacing: 8) {
            Text("\((viewModel.currentHitIndex ?? 0) + 1) of \(viewModel.hits.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            FindNavigationControl(
                onPrevious: { viewModel.navigateToOlderHit() },
                onNext: { viewModel.navigateToNewerHit() }
            )
            // §8.38(8): content-sized, never stretched across the bar — the
            // representable takes the full width proposal without this.
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var chat: some View {
        // §4.6 rendering engine (§8.38): the message flow — bands, Markdown,
        // fold controls, highlights, and the hit ticks — renders in the
        // bundled page; header, find bar, and Resume stay native. Scroll
        // default (bottom = latest), scroll memory, and jump-to-hit are
        // driven through the bridge; the ⌘± text size flows into the page's
        // CSS variable.
        WebPaneView(controller: viewModel.webPane)
            .onAppear { viewModel.webPane.setTextSize(bodySize) }
            .onChange(of: bodySize) { _, newSize in
                viewModel.webPane.setTextSize(newSize)
            }
    }
}
