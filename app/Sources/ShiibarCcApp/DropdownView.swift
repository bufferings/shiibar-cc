// Dropdown custom view (the dropdown section of menubar-design.html,
// DESIGN.md §4.5): ⌄ menu (Rescan / Start at Login / Sort by / Mute Sound /
// Quit), warning rows (disconnected / notification permission denied /
// focus TCC error), a flat list with a leading status symbol (default) or
// grouped cards (Waiting / Working / Idle, empty groups hidden) depending
// on the "Sort by" selection, two-line rows with unreviewed bolding + a
// symbol-shoulder badge, row click -> focus. Every clickable element (rows,
// the ⌄ chip) gets a hover/press highlight (menubar-design.html's
// hover/press section — session rows use the selection color, the ⌄ chip
// uses a persistent gray, M5 T2 follow-up); non-interactive elements (group
// headers, warning rows) get none.

import ShiibarCcCore
import SwiftUI

struct DropdownView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TopBar(state: state)

            // Elapsed times are computed against `dropdownOpenedAt` — the
            // instant this open of the dropdown was captured (DESIGN.md
            // §4.5: fixed while open, no per-second ticking, fresh on
            // reopen). The capture is @Published, so the reopen refresh
            // re-renders these rows; agent changes while open still render
            // immediately via `agents`, only the elapsed base stays put
            // (Grouping's max(0, now - since) clamps rows whose transition
            // happens after the capture). Row *order* in the two flat modes
            // instead comes from `flatOrderSnapshot` (also settled at open,
            // §4.5) — see `AppState.flatRows`.
            if state.sortMode == .grouped {
                let groups = state.groups(now: state.dropdownOpenedAt)
                if groups.isEmpty {
                    NoAgentsRow()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(groups) { group in
                                GroupSection(group: group, state: state)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
            } else {
                let rows = state.flatRows(now: state.dropdownOpenedAt)
                if rows.isEmpty {
                    NoAgentsRow()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(rows) { row in
                                RowView(row: row, state: state)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(maxHeight: 360)
                }
            }

            // Warning rows live at the BOTTOM of the dropdown (DESIGN.md
            // §4.5 / menubar-design.html: the tray-wide grayout is the
            // primary disconnect signal, so the agent list gets priority).
            // Monochrome + ⚠, never red (red = unreviewed only), no click
            // action (triage belongs to `shiibar-cc doctor`).
            if !state.connected {
                WarningRow(text: "Disconnected from daemon — reconnecting…")
            }
            if state.notificationManager.permissionDenied {
                WarningRow(text: "Notifications permission denied")
            }
            if state.tccWarning {
                WarningRow(text: "Automation permission needed (run \"shiibar-cc doctor\")")
            }
        }
        .padding(.vertical, 6)
        .frame(width: 340)
        // Belt and braces for the per-open capture: the primary signal is
        // NSWindow.didBecomeKeyNotification (see AppState.observeDropdownOpen
        // — the hosted view stays alive across open/close, so onAppear may
        // fire only once at launch). If some macOS version does remount the
        // view per open, both triggers land on the same second — harmless.
        .onAppear { state.captureDropdownOpenTime() }
    }
}

private struct TopBar: View {
    @ObservedObject var state: AppState
    @State private var isHoveringVButton = false
    @State private var isPressingVButton = false

    /// The ⌄ chip's gray background opacity (T2 follow-up, M5;
    /// menubar-design.html: base ~.14, hover ~.22, press ~.30).
    private var chipBackgroundOpacity: Double {
        if isPressingVButton { return 0.30 }
        if isHoveringVButton { return 0.22 }
        return 0.14
    }

    var body: some View {
        HStack {
            Menu {
                // The ⌄ POPUP's items (Rescan / Mute Sound / Quit) are a
                // native SwiftUI Menu, so macOS draws its usual
                // highlighted-row style on the open popup itself — no
                // custom hover handling for the popup items here.
                Button("Rescan") { state.runReconcile(showFeedback: true) }
                // "Start at Login" reads `SMAppService.mainApp.status`
                // fresh on every render (DESIGN.md §4.5, M5 T3: no cached
                // source of truth, so it can't drift from System Settings'
                // own Login Items UI). Toggling calls register()/
                // unregister() directly. The refresh trigger for "fresh on
                // every render" is the same one that already drives every
                // other per-open dropdown value: `state.dropdownOpenedAt`
                // changing is a `@Published` write on this `@ObservedObject`,
                // which re-invokes this whole body (including this Menu's
                // content closure) on each dropdown open — see
                // `AppState.observeDropdownOpen`.
                Toggle("Start at Login", isOn: Binding(
                    get: { state.loginItemEnabled },
                    set: { _ in state.toggleLoginItem() }
                ))
                // "Sort by" (§4.5, M5 T9): three radio-style items between
                // Start at Login and Mute Sound (menubar-design.html's
                // v-menu bullet ordering). A `Picker` with `.inline` style
                // inside a `Menu` is what SwiftUI/AppKit render as a
                // checkmark-on-the-active-item radio group.
                Menu("Sort by") {
                    Picker("Sort by", selection: Binding(
                        get: { state.sortMode },
                        set: { state.setSortMode($0) }
                    )) {
                        ForEach(SortMode.allCases, id: \.self) { mode in
                            Text(mode.menuTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                }
                // A Toggle inside a Menu renders the native menu checkmark
                // while muted (the spec's "checkmark while muted").
                Toggle("Mute Sound", isOn: Binding(
                    get: { state.muted },
                    set: { _ in state.toggleMute() }
                ))
                Divider()
                Button("Quit") { state.quit() }
            } label: {
                // T2 follow-up (M5): the chip's text color never changes on
                // hover/press — only the background does, below.
                Text("⌄")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    // U+2304 sits low in its em box; nudge it up so it
                    // reads centered in the chip (menubar-design.html's
                    // .vbtn look: a rounded chip with the glyph centered).
                    .offset(y: -1.5)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            // The macOS Menu draws its own pull-down disclosure indicator
            // next to the label, which stacked a second chevron under our ⌄
            // text (seen on-device). Hide it so exactly one ⌄ shows. If a
            // macOS version ignores `menuIndicator(.hidden)` for this style,
            // the fallback is the inverse: keep the system indicator and
            // make the label empty.
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // The ⌄ CHIP (as opposed to its popup items, or a session row)
            // gets its OWN treatment (T2 follow-up, M5): a persistent gray
            // chip background — never the selection color — that darkens on
            // hover and darkens further while pressed (menubar-design.html:
            // ~.14 / .22 / .30 opacity steps). `.onHover` toggles the hover
            // state; press is tracked with a `DragGesture(minimumDistance:
            // 0)` rather than a `ButtonStyle` (which `Menu` doesn't expose a
            // pressed state through) — `.simultaneousGesture` only OBSERVES
            // the press, leaving Menu's own tap gesture (which opens the
            // popup) intact.
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.gray.opacity(chipBackgroundOpacity))
            )
            .onHover { isHoveringVButton = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressingVButton = true }
                    .onEnded { _ in isPressingVButton = false }
            )

            // Manual-Rescan transient feedback (§4.5/§9), unclickable,
            // secondary-color 12px text to the right of ⌄.
            if let feedback = state.rescanFeedback {
                Text(feedback.topbarText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }
}

private extension RescanFeedback {
    /// UI text (English; menubar-design.html: "Rescanning…" / "✓ Rescan
    /// done" / "Rescan failed", no counts).
    var topbarText: String {
        switch self {
        case .running: return "Rescanning…"
        case .success: return "✓ Rescan done"
        case .failure: return "Rescan failed"
        }
    }
}

private struct NoAgentsRow: View {
    var body: some View {
        Text("No agents")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

private struct WarningRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text("⚠")
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

private struct GroupSection: View {
    let group: AgentGroup
    @ObservedObject var state: AppState

    private var heading: String {
        switch group.status {
        case .waiting: return "Waiting"
        case .working: return "Working"
        case .idle: return "Idle"
        case .unknown: return "Idle" // unreachable: Grouping.groupOrder never yields .unknown
        }
    }

    /// The header shows the tray-shaped window glyph carrying this group's
    /// own status character (menubar-design.html: group heading = window
    /// icon of the same shape as the tray, ~24px, + bold label).
    private var headerGlyph: TrayGlyph {
        switch group.status {
        case .waiting: return .waiting
        // The header glyph is static (menubar-design.html: no animation on
        // the group heading), so frame 0 always — only the tray's own
        // rendering animates (`TrayIconRenderer`).
        case .working: return .working(frame: 0)
        case .idle: return .idle
        case .unknown: return .idle // unreachable, as above
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                WindowGlyphView(glyph: headerGlyph, size: 24)
                    // Optical adjustment from the mock: the label sits on the
                    // icon's vertical center, icon nudged up ~1.5pt.
                    .offset(y: -1.5)
                Text(heading)
                    .font(.system(size: 13, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            VStack(spacing: 1) {
                ForEach(group.rows) { row in
                    RowView(row: row, state: state)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.09)))
            .padding(.horizontal, 4)
        }
    }
}

/// Selection-color hover/press highlight shared by every Button-based
/// clickable row in the dropdown (menubar-design.html's hover/press bullet:
/// rounded 7px, system selection color so it tracks the user's accent color
/// rather than the mock's literal #3478f6, one step darker while pressed).
/// `isHovering` comes from the caller's own `.onHover` (SwiftUI's
/// `ButtonStyle` has no hover state of its own); `configuration.isPressed`
/// is what `ButtonStyle` DOES expose, so press-darkening lives here.
private struct HighlightButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
                    .brightness(configuration.isPressed ? -0.15 : 0)
                    .opacity(isHovering ? 1 : 0)
            )
    }
}

private struct RowView: View {
    let row: AgentRow
    @ObservedObject var state: AppState
    @State private var isHovering = false

    /// `nil` only for a status this build doesn't lay out (`.unknown`) —
    /// `RowSymbol.kind` already excludes it elsewhere (`Sorting.flatOrder`,
    /// `Grouping.groupOrder`), so a row with `nil` here shouldn't occur in
    /// practice; falling back to `.idle`'s empty circle is a harmless,
    /// non-crashing default rather than an unreachable-code assumption.
    private var symbolKind: RowSymbolKind {
        RowSymbol.kind(for: row.status) ?? .idle
    }

    var body: some View {
        Button {
            state.rowClicked(target: row.target)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                // §4.5/M5 T9: the leading status symbol replaces the old
                // row-right red dot — unreviewed now badges the symbol's
                // top-right shoulder instead.
                RowSymbolView(
                    kind: symbolKind,
                    unreviewed: row.unreviewed,
                    spinning: state.isDropdownOpen && symbolKind == .working
                )
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.primaryLine)
                        .font(.system(size: 12, weight: row.unreviewed ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // menubar-design.html: hovered row text switches to
                        // the selection foreground (white in the mock).
                        .foregroundStyle(isHovering ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    Text("\(row.label) · \(ElapsedTime.format(seconds: row.elapsedSeconds))")
                        .font(.system(size: 10))
                        .foregroundStyle(isHovering ? AnyShapeStyle(Color.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
    }
}
