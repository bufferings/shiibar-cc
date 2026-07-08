// Dropdown custom view (the dropdown section of menubar-design.html,
// DESIGN.md §4.5/§8.25): ⌄ menu (Rescan / Clear badges / Sort by / Settings…
// / Setup Check… / About Shiibar CC / Quit, grouped into three sections by
// two separators — Settings… opens the independent Settings window, M14 T1;
// it replaced the old Settings submenu), warning rows (disconnected /
// notification permission denied / focus TCC error), a flat list with a
// leading status symbol (default) or grouped cards (Waiting / Working /
// Idle, empty groups hidden) depending on the "Sort by" selection, two-line
// rows with unreviewed bolding + a symbol-shoulder badge, row click -> focus.
// Every clickable element (rows, the ⌄ chip) gets a hover/press highlight
// (menubar-design.html's hover/press section — session rows use the
// selection color, the ⌄ chip uses a persistent gray, M5 T2 follow-up);
// non-interactive elements (group headers, warning rows) get none.

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
    /// Retains the NSMenu action target while the popup is up
    /// (NSMenuItem.target is weak, so someone must own the handler).
    @State private var menuHandler = VMenuHandler()
    @State private var menuAnchor: NSView?
    /// Opens the Setup Check window (§4.5, M5 T5) — a SwiftUI `Window`
    /// scene declared alongside `MenuBarExtra` in `ShiibarCcMenuBarApp`.
    /// Only available as an `@Environment` value inside a View, so it's
    /// captured here and handed to `menuHandler` at menu-build time (same
    /// pattern as `state` below).
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            // The v chip is a plain Button + a hand-rolled NSMenu popup.
            // SwiftUI's `Menu` imposes its own label layout on macOS and
            // kept rendering the glyph floating top-left regardless of
            // padding/frame styling; plain Buttons demonstrably render
            // correctly in this window (every session row is one), and
            // AppKit's NSMenu needs no styling at all — checkmarks,
            // submenus and hover come from the system.
            Button {
                presentMenu()
            } label: {
                Text("⌄")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    // U+2304 sits low in its em box; nudge it up so it
                    // reads optically centered in the chip.
                    .offset(y: -1.5)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ChipButtonStyle(isHovering: isHoveringVButton))
            .onHover { isHoveringVButton = $0 }
            .background(MenuAnchorView { menuAnchor = $0 })

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

    /// Builds the ⌄ menu (Rescan / Clear badges / Sort by / Settings… /
    /// Setup Check… / About Shiibar CC / Quit, §4.5/§8.25) fresh on every
    /// click, so checkmarks and Clear badges' enabled state always show the
    /// live state.
    ///
    /// Every item, including the Sort by radio choices, is a plain
    /// `NSMenuItem` with a `target`/`action` via `makeItem`/`VMenuHandler` —
    /// clicking any of them closes the menu (§4.5: "menu items all close on
    /// click, Sort's radios too").
    private func presentMenu() {
        guard let anchor = menuAnchor else { return }
        menuHandler.state = state
        menuHandler.openWindow = openWindow

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(makeItem("Rescan", action: #selector(VMenuHandler.rescan)))
        // §4.5/§8.24: disabled when nothing is unreviewed — clicking it
        // would otherwise be a silent no-op.
        menu.addItem(
            makeItem(
                "Clear badges",
                action: #selector(VMenuHandler.clearBadges),
                isEnabled: state.hasUnreviewed
            )
        )

        // §4.5/§8.25 ⌄ menu grouping: Operations (above) / Display &
        // Settings (below) / App itself (further below) — three groups,
        // two separators.
        menu.addItem(.separator())

        let sort = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        sortMenu.autoenablesItems = false
        for mode in SortMode.allCases {
            let item = makeItem(mode.menuTitle, action: #selector(VMenuHandler.selectSortMode(_:)))
            item.state = state.sortMode == mode ? .on : .off
            item.representedObject = mode
            sortMenu.addItem(item)
        }
        sort.submenu = sortMenu
        menu.addItem(sort)

        // Settings… (§4.5/§8.26, M14 T1): a plain action item that opens the
        // independent Settings window, replacing the old inline submenu of
        // toggles (Start at Login / Mute Banners / Mute Sound all moved into
        // that window — Mute Banners itself was removed entirely, §8.27).
        menu.addItem(makeItem("Settings…", action: #selector(VMenuHandler.openSettings)))
        menu.addItem(makeItem("Setup Check…", action: #selector(VMenuHandler.openSetupCheck)))

        // §4.5/§8.25 ⌄ menu ordering: Rescan / Clear badges / Sort by /
        // Settings… / Setup Check… / About Shiibar CC / Quit, grouped into
        // three sections by two separators (Operations / Display & Settings
        // / App itself — About moved to sit directly above Quit, matching
        // the macOS convention of About-then-Quit at the bottom).
        menu.addItem(.separator())
        menu.addItem(makeItem("About Shiibar CC", action: #selector(VMenuHandler.showAbout)))
        menu.addItem(makeItem("Quit", action: #selector(VMenuHandler.quit)))

        // Position in SCREEN coordinates (in: nil) so the result doesn't
        // depend on the anchor view's flippedness: screen y grows upward,
        // the menu's top-left lands on the given point, so "just below the
        // chip" is the chip's screen minY minus a small gap.
        guard let window = anchor.window else { return }
        let rectInWindow = anchor.convert(anchor.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: screenRect.minX, y: screenRect.minY - 4),
            in: nil
        )
        // popUp is synchronous (returns when the menu closes). Opening the
        // menu made the dropdown panel resign key, which flips
        // `isDropdownOpen` false and pauses the row spinners; hand key
        // status back so they resume (e.g. right after switching Sort by).
        window.makeKey()
    }

    private func makeItem(_ title: String, action: Selector, isEnabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = menuHandler
        item.isEnabled = isEnabled
        return item
    }
}

/// NSMenu action target bridging back into `AppState`. NSMenu fires
/// actions on the main thread; the @MainActor annotation makes that
/// assumption explicit to the compiler.
@MainActor
private final class VMenuHandler: NSObject {
    weak var state: AppState?
    /// Set fresh on every `presentMenu()` call (`OpenWindowAction` is a
    /// plain struct, not a class, so there's no lifetime/retain concern
    /// with re-assigning it each time, unlike `state` above).
    var openWindow: OpenWindowAction?

    @objc func rescan(_ sender: Any?) { state?.runReconcile(showFeedback: true) }
    @objc func clearBadges(_ sender: Any?) { state?.clearBadges() }
    /// Sort by radio choice (§4.5/§8.25). A plain action item like every
    /// other ⌄ menu row now — AppKit closes the menu on dispatch the same
    /// way it does for Rescan/Clear badges/etc, no keep-open special case.
    @objc func selectSortMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? SortMode else { return }
        state?.setSortMode(mode)
    }
    /// §4.5/§8.24: `NSApp.activate` before the standard About panel, same
    /// LSUIElement requirement as `openSetupCheck` below (an LSUIElement
    /// app doesn't automatically come forward when it shows a window).
    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(sender)
    }
    @objc func openSetupCheck(_ sender: Any?) {
        // Moving to a real window: the dropdown's job is done, close it
        // (same as a row click does).
        state?.dismissDropdown()
        // NSApp.activate happens again in SetupCheckView.onAppear — doing
        // it here too covers the case where the window is already open
        // (onAppear won't refire) and just needs to come forward.
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: SetupCheckWindow.id)
    }
    /// Settings… (§4.5/§8.26, M14 T1): same pattern as `openSetupCheck`
    /// above.
    @objc func openSettings(_ sender: Any?) {
        state?.dismissDropdown()
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: SettingsWindow.id)
    }
    @objc func quit(_ sender: Any?) { state?.quit() }
}

/// The ⌄ chip's persistent background (T2 follow-up, M5) — never the
/// selection color. Primary-based rather than gray: the dropdown sits on
/// a light-gray material, and gray at mock opacity vanished against it
/// on-device; the foreground color at these opacities stays visible on
/// both light and dark appearances.
private struct ChipButtonStyle: ButtonStyle {
    let isHovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(
                        configuration.isPressed ? 0.24 : isHovering ? 0.16 : 0.10
                    ))
            )
    }
}

/// Zero-sized AppKit view whose only job is handing an `NSView` reference
/// to SwiftUI so `NSMenu.popUp(positioning:at:in:)` has a host view.
private struct MenuAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
            .font(.system(size: 13))
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
        .font(.system(size: 12))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Text-only heading (dropdown redesign mock: no window icon).
            Text(heading)
                .font(.system(size: 13, weight: .bold))
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

    /// Hover highlight, gated on the dropdown actually being open: while
    /// the panel fades out (row click / focus / outside click), the window
    /// resigns key first, so this flips false and the closing animation
    /// never shows a selection-blue row frozen mid-fade.
    private var showsHighlight: Bool {
        isHovering && state.isDropdownOpen
    }

    var body: some View {
        Button {
            state.rowClicked(target: row.target)
        } label: {
            HStack(alignment: .center, spacing: 12) {
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
                        .font(.system(size: 13, weight: row.unreviewed ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // menubar-design.html: hovered row text switches to
                        // the selection foreground (white in the mock).
                        .foregroundStyle(showsHighlight ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    Text("\(row.label) · \(ElapsedTime.format(seconds: row.elapsedSeconds))")
                        .font(.system(size: 11))
                        .foregroundStyle(showsHighlight ? AnyShapeStyle(Color.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 4)
            }
            // Leading inset tuned on-device (2026-07-05): slightly tighter
            // than the 12pt symbol-to-text gap reads as centered.
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightButtonStyle(isHovering: showsHighlight))
        .onHover { isHovering = $0 }
    }
}
