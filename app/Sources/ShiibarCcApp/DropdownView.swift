// Dropdown custom view (the dropdown section of menubar-design.html,
// DESIGN.md §4.5/§8.24): ⌄ menu (Rescan / Clear badges / Sort by / Settings
// [Start at Login / Mute Banners / Mute Sound] / About Shiibar CC / Setup
// Check… / Quit), warning rows (disconnected / notification permission denied /
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

    /// Builds the ⌄ menu (Rescan / Clear badges / Sort by / Settings / About
    /// Shiibar CC / Setup Check… / Quit, §4.5/§8.24) fresh on every click, so
    /// checkmarks and Clear badges' enabled state always show the live
    /// state.
    ///
    /// The CHECK rows below (Sort by's 3 radio choices, Settings' 3
    /// toggles) are `CheckMenuItemView`s, not plain `NSMenuItem`s with an
    /// action — §4.5's uncommitted keep-open clause says clicking a CHECK
    /// item must NOT close the menu, and a custom `view` is the only
    /// supported way to get that: AppKit only auto-closes the menu for its
    /// own action-dispatch path, never for a view that handles its own
    /// mouse events. Action items (Rescan / Clear badges / About Shiibar CC /
    /// Setup Check… / Quit) are unchanged plain items via
    /// `makeItem`/`VMenuHandler`.
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

        let sort = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        sortMenu.autoenablesItems = false
        let sortModes = SortMode.allCases
        let sortViews = sortModes.map { mode in
            CheckMenuItemView(title: mode.menuTitle, isOn: state.sortMode == mode)
        }
        // Weak boxes, not the views themselves, are what each closure
        // below captures — the views already form the strong-ownership
        // chain menu -> sortMenu -> item -> view, and each view also
        // retains its own `onSelect` closure; capturing the sibling views
        // directly here would close a retain cycle that outlives the menu
        // (this whole tree is rebuilt from scratch on every ⌄ click, so a
        // cycle here would leak on every open).
        let sortViewBoxes = sortViews.map(WeakBox.init)
        for (mode, view) in zip(sortModes, sortViews) {
            let item = NSMenuItem(title: mode.menuTitle, action: nil, keyEquivalent: "")
            item.view = view
            sortMenu.addItem(item)
            view.onSelect = { [weak state] in
                state?.setSortMode(mode)
                // Radio semantics: only one of the three can be on, so a
                // click refreshes all three sibling checkmarks in place.
                for (siblingMode, box) in zip(sortModes, sortViewBoxes) {
                    box.value?.setOn(siblingMode == mode)
                }
            }
        }
        sort.submenu = sortMenu
        menu.addItem(sort)

        // Rarely-touched switches live one level down (§4.5: Settings
        // submenu below Sort by), ordered Start at Login / Mute Banners /
        // Mute Sound. "Start at Login" reads `SMAppService.mainApp.status`
        // live via `state.loginItemEnabled` at menu-build time, so it can't
        // drift from System Settings. The two mute checkmarks are read live
        // from `state` the same way — independent switches (§4.5/§8.14
        // 2026-07-05 addendum), checkmark = muted. Each is its own
        // independent toggle (not a radio group), so a click only ever
        // refreshes its own checkmark.
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        settingsMenu.autoenablesItems = false

        let loginItem = NSMenuItem(title: "Start at Login", action: nil, keyEquivalent: "")
        let loginView = CheckMenuItemView(title: "Start at Login", isOn: state.loginItemEnabled)
        loginItem.view = loginView
        settingsMenu.addItem(loginItem)
        loginView.onSelect = { [weak state, weak loginView] in
            state?.toggleLoginItem()
            loginView?.setOn(state?.loginItemEnabled ?? false)
        }

        let muteBannersItem = NSMenuItem(title: "Mute Banners", action: nil, keyEquivalent: "")
        let muteBannersView = CheckMenuItemView(title: "Mute Banners", isOn: state.bannersMuted)
        muteBannersItem.view = muteBannersView
        settingsMenu.addItem(muteBannersItem)
        muteBannersView.onSelect = { [weak state, weak muteBannersView] in
            state?.toggleMuteBanners()
            muteBannersView?.setOn(state?.bannersMuted ?? false)
        }

        let muteItem = NSMenuItem(title: "Mute Sound", action: nil, keyEquivalent: "")
        let muteView = CheckMenuItemView(title: "Mute Sound", isOn: state.muted)
        muteItem.view = muteView
        settingsMenu.addItem(muteItem)
        muteView.onSelect = { [weak state, weak muteView] in
            state?.toggleMute()
            muteView?.setOn(state?.muted ?? false)
        }

        settings.submenu = settingsMenu
        menu.addItem(settings)

        // §4.5/§8.24 ⌄ menu ordering: Rescan / Clear badges / Sort by /
        // Settings / About Shiibar CC / Setup Check… / Quit.
        menu.addItem(makeItem("About Shiibar CC", action: #selector(VMenuHandler.showAbout)))
        menu.addItem(makeItem("Setup Check…", action: #selector(VMenuHandler.openSetupCheck)))

        menu.addItem(.separator())
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
    @objc func quit(_ sender: Any?) { state?.quit() }
}

/// A non-retaining reference, used so a closure can hold onto a sibling
/// `CheckMenuItemView` (to refresh its checkmark) without joining a retain
/// cycle with that view's own `onSelect` closure.
private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// A CHECK-style ⌄ submenu row (one of Sort by's 3 radio choices, or one
/// of Settings' 3 toggles). This is an `NSMenuItem`'s custom `view`, not a
/// plain item with a `target`/`action` — that's the load-bearing choice
/// (§4.5's keep-open clause): AppKit only auto-closes an open menu when
/// *it* dispatches an item's action; a view that handles its own mouse
/// events owns tracking, and the menu stays open unless the view calls
/// `NSMenu.cancelTracking()` — which `mouseUp` here never does.
///
/// Metrics mirror the native check-item look at `NSFont.menuFont(ofSize:
/// 13)`: a leading checkmark column, then the label, in a row sized to
/// match a native item at this font (so the "Sort by"/"Settings"
/// submenus don't look like a foreign control next to the rest of the ⌄
/// menu — tune `rowHeight` on-device if it doesn't line up).
///
/// Keyboard navigation of these rows is degraded: AppKit only drives
/// arrow-key/Return highlighting for its own item cells, never for a
/// custom `view`. Accepted trade-off for the keep-open behavior — mouse
/// interaction (the only way these items are meant to be used, same as
/// every other row in this dropdown) is unaffected.
private final class CheckMenuItemView: NSView {
    static let rowHeight: CGFloat = 22
    static let checkColumnWidth: CGFloat = 20
    private static let horizontalTrailingInset: CGFloat = 14
    private static let highlightInsetX: CGFloat = 5
    fileprivate static let highlightCornerRadius: CGFloat = 4

    /// Set post-init (not an init parameter) so callers can build every
    /// sibling row first and only then wire closures that reference each
    /// other (the sort radio group's "refresh all three" needs the full
    /// sibling list to exist before any of them can be clicked).
    var onSelect: () -> Void = {}

    private let checkLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    /// Native menus draw their selection as a vibrancy MATERIAL, not a
    /// flat color fill — a solid selectedContentBackgroundColor visibly
    /// mismatches the neighboring native items' blue. NSVisualEffectView
    /// with the .selection material (emphasized) is the same mechanism the
    /// system uses, so mixed native/custom rows highlight identically.
    private let highlightView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .selection
        view.state = .active
        view.isEmphasized = true
        view.blendingMode = .behindWindow
        view.wantsLayer = true
        view.layer?.cornerRadius = CheckMenuItemView.highlightCornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.isHidden = true
        return view
    }()
    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false {
        didSet { updateColors() }
    }

    init(title: String, isOn: Bool) {
        let font = NSFont.menuFont(ofSize: 13)
        let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let width = Self.checkColumnWidth + ceil(titleWidth) + Self.horizontalTrailingInset
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        // The initial frame width is only this row's MINIMUM (it feeds the
        // menu's width calculation); AppKit then stretches every item view
        // to the final menu width when the mask allows it — which is what
        // makes hover and the highlight reach the menu's right edge, like
        // native items.
        autoresizingMask = [.width]

        highlightView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlightView)
        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.highlightInsetX),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.highlightInsetX),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])

        checkLabel.font = font
        checkLabel.alignment = .center
        titleLabel.font = font
        titleLabel.stringValue = title
        for label in [checkLabel, titleLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.backgroundColor = .clear
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            checkLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            checkLabel.widthAnchor.constraint(equalToConstant: Self.checkColumnWidth - 4),
            checkLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.checkColumnWidth),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Self.horizontalTrailingInset
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)

        setOn(isOn)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Repaints just the checkmark glyph — called at build time and again
    /// right after a click, so the row reflects the new state without
    /// rebuilding the whole menu (rebuilding only happens on the NEXT ⌄
    /// open, so the menu can stay open per §4.5).
    func setOn(_ isOn: Bool) {
        checkLabel.stringValue = isOn ? "✓" : ""
        setAccessibilityValue(isOn ? "on" : "off")
    }

    private func updateColors() {
        highlightView.isHidden = !isHighlighted
        let color: NSColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        checkLabel.textColor = color
        titleLabel.textColor = color
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
    }

    /// This also covers the "clear on menu close" requirement in practice:
    /// the whole ⌄ menu (and every view in it) is discarded and rebuilt
    /// fresh on each `presentMenu()` call, so there's no cross-open
    /// highlight state to leak — only the within-one-open hover case
    /// (handled here) is real.
    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect()
    }

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
