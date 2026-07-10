// Shared agent list content (DESIGN.md §4.5's "the agent list window" bullet, M26
// T1): the list (flat with a leading status symbol, or grouped cards) /
// "No agents" / warning rows — displayed identically by the dropdown panel
// (DropdownView) and the Open-as-Window `Agents` window (AgentsWindowView).
// The ⌄ top bar is DROPDOWN-ONLY (§4.5/§8.30, M27 T3: the window carries no
// resident low-frequency verbs — those live in the app menu, `AppMenu.swift`,
// which exists while the window does). `AgentListContainer` below is the
// only seam — it carries the handful of things that legitimately differ per
// container: the top bar's presence, row-click dismissal, the spinner/hover
// gate, the elapsed-time base, and where the manual-Rescan transient
// feedback renders (dropdown: next to the ⌄ chip; window: a bottom status
// line, M27 T3). Row order carries no per-container state — both containers
// order live from `agents` by the immutable `created_at` (§8.31).
//
// Every clickable element (rows, the ⌄ chip) gets a hover/press highlight
// (menubar-design.html's hover/press section — session rows use the
// selection color, the ⌄ chip uses a persistent gray, M5 T2 follow-up);
// non-interactive elements (group headers, warning rows) get none.

import ShiibarCcCore
import SwiftUI

/// The differences between the dropdown panel and the Open-as-Window
/// `Agents` window as hosts for `AgentListView` (DESIGN.md §4.5, M26 T1).
struct AgentListContainer {
    enum Kind: Equatable {
        case dropdown
        case window
    }

    let kind: Kind
    /// Elapsed-time base for the visible rows (§4.5): dropdown =
    /// `AppState.dropdownOpenedAt` (fixed while open, refreshed on
    /// reopen); window = `AgentsWindowViewModel.openedAt` (taken at open,
    /// re-taken every 60s while visible, M26 T3). The two are never
    /// shared — each container keeps its own basis so having both open at
    /// once doesn't let one disturb the other (T3). Row ORDER carries no
    /// such per-container state: both modes order live from `agents` by
    /// the immutable `created_at` on every render (§8.31).
    let openedAt: Int64
    /// Gates the row spinner and hover highlight (§4.5): dropdown =
    /// `AppState.isDropdownOpen`; window = `AgentsWindowViewModel.isVisible`.
    let isActive: Bool
    /// Dropdown only (§4.5/§8.32, M29 T1): `visibleFrame` height of the
    /// display the dropdown opened on (`AppState.dropdownScreenVisibleHeight`,
    /// captured per open), from which the list's height cap is computed so
    /// the WHOLE dropdown fits the visible area. `nil` for the window —
    /// its list fills whatever height the user gave the window (M29 T2),
    /// no screen-derived cap.
    let screenVisibleHeight: Double?

    /// The ⌄ top bar is dropdown-only (§4.5/§8.30, M27 T3): the Agents
    /// window's content is the list and warning rows alone — its verbs
    /// live in the app menu instead (`AppMenuCommands`).
    var showsTopBar: Bool { kind == .dropdown }
    /// Where the manual-Rescan transient feedback renders (§4.5, M27 T3):
    /// the dropdown shows it next to the ⌄ chip (in the top bar); the
    /// window — having no top bar — shows it as a bottom status line in
    /// the warning-row slot.
    var showsRescanFeedbackStatusLine: Bool { kind == .window }
    /// Row click (§4.5 M26 T1): dropdown focuses AND closes (existing
    /// `AppState.rowClicked` behavior, unchanged); the window only
    /// focuses, so a run of waiting agents can be resolved one after
    /// another without the list disappearing.
    var dismissesOnRowClick: Bool { kind == .dropdown }
    /// Click-through for rows (§4.5, M29 bugfix): in the Agents window,
    /// rows act on the FIRST click even while the window is unfocused —
    /// the window exists for glance-and-jump, no throwaway activation
    /// click. Window only: the dropdown panel is key whenever it is
    /// visible, so first-mouse gating never comes up there.
    var firesOnFirstClick: Bool { kind == .window }
}

/// `NSHostingView` that answers `acceptsFirstMouse` with true, so the
/// SwiftUI content it hosts receives the click that also activates a
/// non-key window (§4.5 click-through, M29 bugfix). Measured on-device: a
/// plain SwiftUI `Button` in a non-key window swallows the first click (it
/// only activates the window; a second click is needed) because AppKit
/// consults `acceptsFirstMouse` on the hit view — the hosting view — and
/// the SwiftUI-provided one declines; the same synthetic first click fires
/// the action once the row is hosted in this subclass.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Wraps one row in a `FirstMouseHostingView`. Scoped to rows on purpose:
/// the traffic-light band keeps its standard drag behavior and nothing
/// else in the window is click-sensitive. Sizing measured on-device:
/// inside a `ScrollView` (the only place rows live) the hosted row adopts
/// its natural height (~47pt) and fills the proposed width, identical to
/// the unwrapped row. Hover state crosses the boundary as ordinary
/// captured state; `updateNSView` re-assigns `rootView` so every outer
/// render reconciles into the hosted tree.
private struct FirstMouseHost<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        FirstMouseHostingView(rootView: content)
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        view.rootView = content
    }
}

struct AgentListView: View {
    @ObservedObject var state: AppState
    let container: AgentListContainer
    /// Natural (uncapped) height of the scroll content, measured by the
    /// GeometryReader background on the list's inner VStack — inside a
    /// ScrollView the content always lays out at its natural height, so
    /// this is exact, not estimated (M29 panel-height bugfix). 0 until the
    /// first layout lands.
    @State private var naturalListHeight: CGFloat = 0

    /// Warning rows currently rendered at the bottom (must mirror the
    /// `WarningRow` conditions in `body`) — feeds the dropdown chrome
    /// estimate below.
    private var warningRowCount: Int {
        (state.connected ? 0 : 1)
            + (state.notificationManager.permissionDenied ? 1 : 0)
            + (state.tccWarning ? 1 : 0)
    }

    /// Estimated height of everything the dropdown draws AROUND the
    /// scrolling list (M29 T1) — the values mirror the layout constants in
    /// this file: outer `.padding(.vertical, 6)` = 12; top bar = 2 top
    /// padding + 24 chip; one 2pt `VStack` spacing above the list; each
    /// warning row ≈ 15pt of 12pt text + 8pt vertical padding + 2pt
    /// spacing. A few points of drift are absorbed by
    /// `AgentListHeights.dropdownBottomMargin`.
    private var dropdownChromeHeight: Double {
        let outerPadding = 12.0
        let topBar = 26.0 + 2.0
        let warningRow = 25.0
        return outerPadding + topBar + Double(warningRowCount) * warningRow
    }

    /// The scrolling list's max height (§4.5/§8.32, M29): dropdown =
    /// content-sized up to "the whole dropdown fits the display's visible
    /// area" (computed per open, see `AgentListContainer.screenVisibleHeight`);
    /// window = fills whatever height the user gave the window (the
    /// `ScrollView` turns greedy and the window, not the content, decides).
    private var listMaxHeight: CGFloat {
        guard let visibleHeight = container.screenVisibleHeight else { return .infinity }
        return CGFloat(AgentListHeights.dropdownListCap(
            visibleFrameHeight: visibleHeight,
            chromeHeight: dropdownChromeHeight
        ))
    }

    /// Explicit ideal for the dropdown's list frame (M29 panel-height
    /// bugfix): min(measured natural height, cap). Load-bearing — measured
    /// on-device, a ScrollView's self-reported ideal plateaus well below
    /// the M29 cap, so `.frame(maxHeight:)` alone never grows the list
    /// past that plateau (the old ~360-era look). `nil` (no override)
    /// until the first measurement lands, and always for the window
    /// container, whose list is sized by the window instead.
    private var listIdealHeight: CGFloat? {
        guard container.kind == .dropdown, naturalListHeight > 0 else { return nil }
        return min(naturalListHeight, listMaxHeight)
    }

    /// What the whole dropdown panel should be tall (list + chrome),
    /// reported to `AppState`, which enforces it on the panel window —
    /// SwiftUI's own MenuBarExtra sizing clamps the panel to ~1/3 of the
    /// display's visible height regardless of the content's ideal
    /// (measured; see `AgentListHeights.dropdownPanelContentHeight`).
    private var desiredPanelHeight: Double? {
        guard container.kind == .dropdown, naturalListHeight > 0,
              let visibleHeight = container.screenVisibleHeight else { return nil }
        return AgentListHeights.dropdownPanelContentHeight(
            naturalListHeight: Double(naturalListHeight),
            listCap: AgentListHeights.dropdownListCap(
                visibleFrameHeight: visibleHeight,
                chromeHeight: dropdownChromeHeight
            ),
            chromeHeight: dropdownChromeHeight
        )
    }

    /// Measures the scroll content's natural height (see
    /// `naturalListHeight`) without affecting layout.
    private var listHeightReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { naturalListHeight = geo.size.height }
                .onChange(of: geo.size.height) { naturalListHeight = $0 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if container.showsTopBar {
                AgentListTopBar(state: state)
            }

            // Elapsed times are computed against `container.openedAt` — the
            // instant this container's current display was captured (§4.5:
            // fixed while open, no per-second ticking; dropdown refreshes on
            // reopen, the Agents window refreshes every 60s while visible,
            // M26 T3). Agent changes still render immediately via `agents`,
            // only the elapsed base stays put (Grouping's max(0, now -
            // since) clamps rows whose transition happens after the
            // capture). Row order in both modes is computed live per render
            // from the immutable `created_at` key (§8.31) — see
            // `AppState.groups`/`flatRows`.
            if state.sortMode == .grouped {
                let groups = state.groups(now: container.openedAt)
                if groups.isEmpty {
                    NoAgentsRow()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(groups) { group in
                                GroupSection(group: group, state: state, container: container)
                            }
                        }
                        .background(listHeightReader)
                    }
                    .frame(idealHeight: listIdealHeight, maxHeight: listMaxHeight)
                }
            } else {
                let rows = state.flatRows(now: container.openedAt)
                if rows.isEmpty {
                    NoAgentsRow()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(rows) { row in
                                RowView(row: row, state: state, container: container)
                            }
                        }
                        .padding(.horizontal, 4)
                        .background(listHeightReader)
                    }
                    .frame(idealHeight: listIdealHeight, maxHeight: listMaxHeight)
                }
            }

            // Warning rows live at the BOTTOM of the list (§4.5/
            // menubar-design.html: the tray-wide grayout is the primary
            // disconnect signal, so the agent list gets priority).
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

            // Manual-Rescan transient feedback (§4.5/§9, M27 T3): the
            // Agents window has no ⌄ top bar to host it, so it renders as
            // a bottom status line in the warning-row slot — same wording
            // and same `RescanFeedback.displaySeconds` clear as the
            // dropdown's chip-adjacent text.
            if container.showsRescanFeedbackStatusLine, let feedback = state.rescanFeedback {
                RescanStatusRow(text: feedback.displayText)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 340)
        // M29 panel-height bugfix: hand the desired whole-panel height to
        // AppState, which enforces it on the MenuBarExtra panel window
        // (SwiftUI's own panel sizing clamps at ~1/3 of the display's
        // visible height — measured). `nil` for the window container and
        // before the first measurement; AppState ignores nil.
        .onAppear { state.setDropdownDesiredPanelHeight(desiredPanelHeight) }
        .onChange(of: desiredPanelHeight) { state.setDropdownDesiredPanelHeight($0) }
    }
}

/// The dropdown's ⌄ top bar (dropdown-only, §4.5/§8.30, M27 T3).
private struct AgentListTopBar: View {
    @ObservedObject var state: AppState
    @State private var isHoveringVButton = false
    /// Retains the NSMenu action target while the popup is up
    /// (NSMenuItem.target is weak, so someone must own the handler).
    @State private var menuHandler = VMenuHandler()
    @State private var menuAnchor: NSView?
    /// Opens the Setup Check / Settings / Agents `Window` scenes declared
    /// alongside `MenuBarExtra` in `ShiibarCcMenuBarApp`. Only available as
    /// an `@Environment` value inside a View, so it's captured here and
    /// handed to `menuHandler` at menu-build time (same pattern as `state`
    /// below).
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
                Text(feedback.displayText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    /// Builds the ⌄ menu fresh on every click, so checkmarks and Clear
    /// badges' enabled state always show the live state. The shared items'
    /// ordering (§4.5/§8.30, M27 T4) is identical to the app menu
    /// (`AppMenuCommands`) — About / - / Settings… / Setup Check… / - /
    /// Rescan / Clear badges / Sort by / - / window verb / Quit. The last
    /// group differs per container: the window verb swaps (Open as Window
    /// here — a ⌄-specific item, the Agents window has no ⌄ — vs Close
    /// Window in the app menu), and Keep on Top, being a property of the
    /// window, exists only in the app menu (§4.5/§8.33, M30).
    ///
    /// Every item, including the Sort by radio choices, is a plain
    /// `NSMenuItem` with a `target`/`action` via `makeItem`/`VMenuHandler` —
    /// clicking any of them closes the menu (§4.5: "menu items all close on
    /// click, Sort's radios too").
    private func presentMenu() {
        guard let anchor = menuAnchor else { return }
        menuHandler.state = state
        menuHandler.openWindow = openWindow
        // Only meaningful for `openAsWindow` — the dropdown panel's own
        // NSWindow, read fresh on every click so the frame captured there
        // is current.
        menuHandler.containerWindow = anchor.window

        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(makeItem("About Shiibar CC", action: #selector(VMenuHandler.showAbout)))
        menu.addItem(.separator())

        // Settings… (§4.5/§8.26, M14 T1): a plain action item that opens the
        // independent Settings window, replacing the old inline submenu of
        // toggles (Start at Login / Mute Banners / Mute Sound all moved into
        // that window — Mute Banners itself was removed entirely, §8.27).
        menu.addItem(makeItem("Settings…", action: #selector(VMenuHandler.openSettings)))
        menu.addItem(makeItem("Setup Check…", action: #selector(VMenuHandler.openSetupCheck)))
        menu.addItem(.separator())

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
        menu.addItem(.separator())

        // Open as Window (§4.5 "the agent list window", M26 T2 / M27 T4): sits
        // where the app menu puts Close Window — both menus end their last
        // group in "window verb + Quit", with the verb swapping per
        // container (the app menu's Keep on Top above its verb is
        // app-menu-only, §4.5/§8.33).
        //
        // Disabled while the Agents window exists (§4.5 — same "disabled
        // when meaningless" convention as Clear badges; raising the open
        // window is Dock click / ⌘Tab's job, and resetting its position is
        // close + reopen). The "window exists" signal is the activation
        // policy: `AgentsWindowViewModel` is the ONLY policy writer and
        // flips it to `.regular` / `.accessory` on exactly this window's
        // title-filtered open/close (M27 T1), so reading it back here is
        // the same state machine with no second derivation to drift. It
        // also gets the minimized case right for free: minimizing fires no
        // `willClose`, so the policy stays `.regular` and the item stays
        // disabled — whereas probing `NSApp.windows` would need the
        // `isVisible || isMiniaturized` subtlety (`isVisible` is false
        // while miniaturized) plus an assumption about whether SwiftUI
        // keeps the closed NSWindow lingering in `NSApp.windows`. The gap
        // between `openWindow(id:)` and the policy flip can't be observed
        // from here: the dropdown (and this menu) is dismissed before the
        // window opens.
        menu.addItem(
            makeItem(
                "Open as Window",
                action: #selector(VMenuHandler.openAsWindow),
                isEnabled: NSApp.activationPolicy() != .regular
            )
        )
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
        // menu made the panel/window resign key, which flips the
        // container's active flag (dropdown: `isDropdownOpen`; window:
        // stays true regardless, see `AgentsWindowViewModel`) and, for the
        // dropdown, pauses the row spinners; hand key status back so they
        // resume (e.g. right after switching Sort by).
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
    /// The dropdown panel's own NSWindow (the ⌄ menu exists only in the
    /// dropdown, §4.5/§8.30, M27 T3) — used by `openAsWindow` to read the
    /// panel's screen frame right before dismissing it.
    var containerWindow: NSWindow?

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
    /// Open as Window (§4.5 "the agent list window", M26 T2). Only reachable
    /// while no Agents window exists — the menu item is disabled otherwise
    /// (§4.5; see `presentMenu`), so this always opens a fresh window.
    ///
    /// Steps, in this order: 1) read the dropdown panel's screen frame
    /// BEFORE dismissing it (dismissing/closing could otherwise change or
    /// invalidate it); 2) ARM the pre-paint placement (`AgentsWindowPlacer`
    /// — position = the panel's top-left, §4.5: always under the icon,
    /// never remembered; height = remembered, else the panel's own height
    /// as the first-open natural fallback, §4.5/M29 T2: the panel holds
    /// the SAME list already laid out content-sized, and its topbar
    /// (~28pt) trades for the window's traffic-light band, so the window
    /// opens as a true pinned dropdown); 3) dismiss the dropdown, bring
    /// the app forward (LSUIElement requirement), and open the window.
    ///
    /// The placement is applied inside the opening window's own
    /// notifications, BEFORE its first paint — a post-`openWindow`
    /// main-queue retry loop was measured to land after the reopen's first
    /// paint (SwiftUI shows its restored frame first), a visible jump. See
    /// `AgentsWindowPlacer` for the measurements.
    @objc func openAsWindow(_ sender: Any?) {
        guard let panelWindow = containerWindow else { return }
        state?.expectAgentsWindowPlacement(
            topLeft: NSPoint(x: panelWindow.frame.minX, y: panelWindow.frame.maxY),
            firstOpenFallbackHeight: Double(panelWindow.frame.height),
            // The display cap for the applied height: the display the
            // dropdown is on — the same one the window is about to open on.
            maximumHeight: Double(panelWindow.screen?.visibleFrame.height ?? .greatestFiniteMagnitude)
        )
        state?.dismissDropdown()
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: AgentsWindow.id)
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
    /// done" / "Rescan failed", no counts). Shared by the dropdown's
    /// chip-adjacent text and the Agents window's bottom status line
    /// (§4.5, M27 T3 — same wording in both containers).
    var displayText: String {
        switch self {
        case .running: return "Rescanning…"
        case .success: return "✓ Rescan done"
        case .failure: return "Rescan failed"
        }
    }
}

/// The Agents window's transient Rescan status line (§4.5, M27 T3): sits
/// in the warning-row slot at the bottom, styled like the dropdown's
/// chip-adjacent feedback (12px secondary, non-interactive) — no ⚠, it is
/// progress feedback, not a warning.
private struct RescanStatusRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
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
    let container: AgentListContainer

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
                    RowView(row: row, state: state, container: container)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.09)))
            .padding(.horizontal, 4)
        }
    }
}

/// Selection-color hover/press highlight shared by every Button-based
/// clickable row in the list (menubar-design.html's hover/press bullet:
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
    let container: AgentListContainer
    @State private var isHovering = false

    /// `nil` only for a status this build doesn't lay out (`.unknown`) —
    /// `RowSymbol.kind` already excludes it elsewhere (`Sorting.newestFirst`,
    /// `Grouping.groupOrder`), so a row with `nil` here shouldn't occur in
    /// practice; falling back to `.idle`'s empty circle is a harmless,
    /// non-crashing default rather than an unreachable-code assumption.
    private var symbolKind: RowSymbolKind {
        RowSymbol.kind(for: row.status) ?? .idle
    }

    /// Hover highlight, gated on the container actually being active
    /// (§4.5 M26 T1): for the dropdown, while the panel fades out (row
    /// click / focus / outside click), the window resigns key first, so
    /// `container.isActive` (`AppState.isDropdownOpen`) flips false and the
    /// closing animation never shows a selection-blue row frozen mid-fade;
    /// for the Agents window, `container.isActive` tracks its own
    /// visibility instead (`AgentsWindowViewModel.isVisible`).
    private var showsHighlight: Bool {
        isHovering && container.isActive
    }

    var body: some View {
        // §4.5 click-through (M29 bugfix): in the Agents window, host the
        // row in a first-mouse-accepting NSHostingView so the click that
        // focuses the window ALSO fires the row (hover already showed the
        // affordance; the first click must honor it). Dropdown rows stay
        // plain — the panel is key whenever visible.
        if container.firesOnFirstClick {
            FirstMouseHost(content: rowButton)
        } else {
            rowButton
        }
    }

    private var rowButton: some View {
        Button {
            // §4.5 M26 T1: the dropdown focuses AND closes (existing
            // `rowClicked` behavior); the Agents window only focuses, so a
            // run of waiting agents can be resolved one after another
            // without the list disappearing.
            if container.dismissesOnRowClick {
                state.rowClicked(target: row.target)
            } else {
                state.focus(target: row.target)
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                // §4.5/M5 T9: the leading status symbol replaces the old
                // row-right red dot — unreviewed now badges the symbol's
                // top-right shoulder instead.
                RowSymbolView(
                    kind: symbolKind,
                    unreviewed: row.unreviewed,
                    spinning: container.isActive && symbolKind == .working
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
