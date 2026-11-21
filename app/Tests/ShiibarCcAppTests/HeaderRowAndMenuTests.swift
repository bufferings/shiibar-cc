import AppKit
import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The header row's buttons (DESIGN.md §4.5 "header row") and the ⌄ menu
/// (§4.5 "⌄ menu"). The menu is built as an `NSMenu` without being shown,
/// and the Refresh icon's view is placed in an offscreen window that is
/// never ordered in, so nothing reaches the screen.
@MainActor
final class HeaderRowAndMenuTests: XCTestCase {
    // MARK: - Header row

    /// Refresh is always the leftmost of the buttons.
    func testHeaderRowButtonOrderPerSurface() {
        XCTAssertEqual(HeaderRowButton.buttons(for: .popover), [.refresh, .openInWindow, .menu])
        XCTAssertEqual(HeaderRowButton.buttons(for: .window), [.refresh, .openInPopover, .pin, .menu])
    }

    func testHeaderRowTooltips() {
        XCTAssertEqual(HeaderRowButton.refresh.tooltip, "Refresh (⌘R)")
        XCTAssertEqual(HeaderRowButton.openInWindow.tooltip, "Open in window")
        XCTAssertEqual(HeaderRowButton.openInPopover.tooltip, "Open in popover")
        XCTAssertEqual(HeaderRowButton.pin.tooltip, "Keep on top")
        XCTAssertNil(HeaderRowButton.menu.tooltip)
    }

    /// Idle: enabled, `Refresh (⌘R)`, still. Running: disabled (no second
    /// trigger), `Refreshing…`, turning unless Reduce Motion is on.
    func testRefreshButtonStateFollowsTheRefreshingFlag() {
        let idle = RefreshButtonState(isRefreshing: false, reduceMotion: false)
        XCTAssertEqual(idle, RefreshButtonState.idle)
        XCTAssertTrue(idle.isEnabled)
        XCTAssertEqual(idle.tooltip, "Refresh (⌘R)")
        XCTAssertFalse(idle.spins)
        XCTAssertEqual(idle.opacity, 1)

        let running = RefreshButtonState(isRefreshing: true, reduceMotion: false)
        XCTAssertFalse(running.isEnabled)
        XCTAssertEqual(running.tooltip, "Refreshing\u{2026}")
        XCTAssertTrue(running.spins)
        XCTAssertEqual(running.opacity, 0.4, "disabled: 40%")

        let reduced = RefreshButtonState(isRefreshing: true, reduceMotion: true)
        XCTAssertFalse(reduced.isEnabled, "Reduce Motion keeps the disabled state")
        XCTAssertEqual(reduced.tooltip, "Refreshing\u{2026}")
        XCTAssertFalse(reduced.spins, "Reduce Motion: no turning")
        XCTAssertEqual(reduced.opacity, 0.4, "disabled: 40% without turning too")

        XCTAssertFalse(RefreshButtonState(isRefreshing: false, reduceMotion: true).spins)
        XCTAssertEqual(RefreshButtonState.accessibilityLabel, "Refresh")
    }

    /// The icon's turning is a layer animation; it needs a window, is
    /// installed again when the view returns to one, and is removed when the
    /// spinning stops (back at rest). The window is never ordered in.
    func testRefreshIconTurnsOnlyWhileSpinningInAWindow() {
        let view = RefreshIconNSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        view.spins = true
        XCTAssertFalse(view.isAnimating, "outside a window nothing turns")

        let window = NSWindow(contentRect: NSRect(x: -40000, y: -40000, width: 24, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        window.contentView = container
        container.addSubview(view)
        XCTAssertTrue(view.isAnimating, "in a window it turns")

        view.removeFromSuperview()
        XCTAssertFalse(view.isAnimating, "leaving the window ends the animation")
        container.addSubview(view)
        XCTAssertTrue(view.isAnimating, "back in a window it turns again")

        view.spins = false
        XCTAssertFalse(view.isAnimating, "stopped at rest")

        // A text size change resizes the icon about the view's center.
        view.iconSize = 20
        view.lineWidth = 1.9
        XCTAssertEqual(view.iconLayerBounds, CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertEqual(view.iconLayerPosition, CGPoint(x: 12, y: 12), "the view's center")
        XCTAssertEqual(RefreshIconNSView.turnSeconds, 1, "§9: one turn per second")
        XCTAssertNil(view.hitTest(NSPoint(x: 12, y: 12)), "clicks reach the button")
    }

    // MARK: - Header row layout

    func testOneColumnLayouts() {
        let popover = HeaderRowLayout(surface: .popover, columns: .one, hitCounterAvailable: true)
        XCTAssertEqual(popover.elements, [.searchField, .button(.refresh), .button(.openInWindow), .button(.menu)],
                       "the counter stays in the detail page's find bar")

        let narrowWindow = HeaderRowLayout(surface: .window, columns: .one, hitCounterAvailable: true)
        XCTAssertEqual(narrowWindow.elements, [
            .trafficLightSpace, .searchField, .button(.refresh), .button(.openInPopover), .button(.pin), .button(.menu),
        ])
    }

    /// Two columns differ from one only by the counter (the field fills
    /// the row in both).
    func testTwoColumnLayout() {
        let withHits = HeaderRowLayout(surface: .window, columns: .two, hitCounterAvailable: true)
        XCTAssertEqual(withHits.elements, [
            .trafficLightSpace, .searchField, .hitCounter,
            .button(.refresh), .button(.openInPopover), .button(.pin), .button(.menu),
        ])
        let withoutHits = HeaderRowLayout(surface: .window, columns: .two, hitCounterAvailable: false)
        XCTAssertEqual(withoutHits.elements,
                       HeaderRowLayout(surface: .window, columns: .one, hitCounterAvailable: false).elements)
    }

    /// In full screen no traffic lights sit at the window's leading edge:
    /// the search field starts at the normal padding, and every other
    /// element stays as in a normal window.
    func testFullScreenWindowHasNoTrafficLightSpace() {
        let oneColumn = HeaderRowLayout(surface: .window, columns: .one, hitCounterAvailable: true, fullScreen: true)
        XCTAssertEqual(oneColumn.elements, [
            .searchField, .button(.refresh), .button(.openInPopover), .button(.pin), .button(.menu),
        ])
        let twoColumns = HeaderRowLayout(surface: .window, columns: .two, hitCounterAvailable: true, fullScreen: true)
        XCTAssertEqual(twoColumns.elements, [
            .searchField, .hitCounter,
            .button(.refresh), .button(.openInPopover), .button(.pin), .button(.menu),
        ])
        let twoColumnsNoHits = HeaderRowLayout(surface: .window, columns: .two, hitCounterAvailable: false, fullScreen: true)
        XCTAssertEqual(twoColumnsNoHits.elements, oneColumn.elements)

        for columns in [ColumnMode.one, .two] {
            let normal = HeaderRowLayout(surface: .window, columns: columns, hitCounterAvailable: true, fullScreen: false)
            XCTAssertEqual(normal.elements.first, .trafficLightSpace, "outside full screen the space stays")
            let full = HeaderRowLayout(surface: .window, columns: columns, hitCounterAvailable: true, fullScreen: true)
            XCTAssertEqual(full.elements, Array(normal.elements.dropFirst()), "only the space goes")
        }
    }

    /// The window's top inset in full screen is the height the title bar
    /// takes over the content; outside full screen it is always 0.
    func testFullScreenTopInset() {
        XCTAssertEqual(WindowFullScreenInset.topInset(fullScreen: true, contentHeight: 1000, contentLayoutHeight: 972), 28)
        XCTAssertEqual(WindowFullScreenInset.topInset(fullScreen: true, contentHeight: 1000, contentLayoutHeight: 1000), 0,
                       "no title bar over the content")
        XCTAssertEqual(WindowFullScreenInset.topInset(fullScreen: true, contentHeight: 1000, contentLayoutHeight: 1010), 0,
                       "never negative")
        XCTAssertEqual(WindowFullScreenInset.topInset(fullScreen: false, contentHeight: 600, contentLayoutHeight: 548), 0,
                       "the windowed layout draws under the title bar")
    }

    func testHitCounterAvailability() {
        XCTAssertTrue(HeaderRowLayout.hitCounterAvailable(conversationShowsMessages: true, hitCount: 3, hasLoadError: false))
        XCTAssertFalse(HeaderRowLayout.hitCounterAvailable(conversationShowsMessages: nil, hitCount: 3, hasLoadError: false),
                       "no conversation")
        XCTAssertFalse(HeaderRowLayout.hitCounterAvailable(conversationShowsMessages: false, hitCount: 3, hasLoadError: false),
                       "a row without messages")
        XCTAssertFalse(HeaderRowLayout.hitCounterAvailable(conversationShowsMessages: true, hitCount: 0, hasLoadError: false),
                       "no hits")
        XCTAssertFalse(HeaderRowLayout.hitCounterAvailable(conversationShowsMessages: true, hitCount: 3, hasLoadError: true),
                       "load error")
    }

    // MARK: - ⌄ menu entries

    private func titles(_ entries: [HeaderMenuEntry]) -> [String] {
        entries.map {
            switch $0 {
            case .separator: return "---"
            case .item(let item): return item.title
            }
        }
    }

    private func item(_ entries: [HeaderMenuEntry], _ command: HeaderMenuItem.Command) -> HeaderMenuItem? {
        for entry in entries {
            if case .item(let item) = entry, item.command == command { return item }
        }
        return nil
    }

    /// Refresh is not in the ⌄ menu (it is the header row's button and ⌘R).
    /// `Archived` follows the separator under `Setup Check…`, before
    /// `Clear badges` (§4.5 "⌄ menu").
    func testMenuItemsAndOrder() {
        let entries = HeaderMenu.entries(hasUnreviewed: true, hasArchived: true, showsArchive: false)
        XCTAssertEqual(titles(entries), [
            "About Shiibar CC", "---", "Settings\u{2026}", "Setup Check\u{2026}", "---",
            "Archived", "Clear badges", "---", "Quit",
        ])
        for entry in entries {
            if case .item(let item) = entry {
                XCTAssertTrue(item.isEnabled, item.title)
                XCTAssertFalse(item.isChecked, item.title)
                XCTAssertFalse(item.title.contains("Refresh"), item.title)
            }
        }
    }

    func testClearBadgesIsDisabledWithNothingUnreviewed() {
        XCTAssertEqual(item(HeaderMenu.entries(hasUnreviewed: false, hasArchived: true, showsArchive: false),
                            .clearBadges)?.isEnabled, false)
        XCTAssertEqual(item(HeaderMenu.entries(hasUnreviewed: true, hasArchived: true, showsArchive: false),
                            .clearBadges)?.isEnabled, true)
    }

    /// §4.5 "⌄ menu": `Archived` is disabled while nothing is archived and
    /// checked while the Archive view is shown.
    func testArchivedIsEnabledByTheArchivedListAndCheckedInTheArchiveView() {
        let cases: [(hasArchived: Bool, showsArchive: Bool, enabled: Bool, checked: Bool)] = [
            (false, false, false, false),
            (true, false, true, false),
            (true, true, true, true),
        ]
        for c in cases {
            let archived = item(HeaderMenu.entries(hasUnreviewed: false, hasArchived: c.hasArchived,
                                                   showsArchive: c.showsArchive), .archived)
            XCTAssertEqual(archived?.title, "Archived")
            XCTAssertEqual(archived?.isEnabled, c.enabled, "\(c)")
            XCTAssertEqual(archived?.isChecked, c.checked, "\(c)")
        }
        let handler = HeaderMenuHandler(controller: nil)
        let checked = handler.menu(for: HeaderMenu.entries(hasUnreviewed: false, hasArchived: true, showsArchive: true))
        XCTAssertEqual(checked.items[5].title, "Archived")
        XCTAssertEqual(checked.items[5].state, .on)
        let unchecked = handler.menu(for: HeaderMenu.entries(hasUnreviewed: false, hasArchived: false, showsArchive: false))
        XCTAssertEqual(unchecked.items[5].state, .off)
        XCTAssertFalse(unchecked.items[5].isEnabled)
    }

    // MARK: - ⌄ menu as built

    func testBuiltMenuHasTheItemsAndTheEnabledFlags() {
        let handler = HeaderMenuHandler(controller: nil)
        let menu = handler.menu(for: HeaderMenu.entries(hasUnreviewed: false, hasArchived: true, showsArchive: false))
        XCTAssertFalse(menu.autoenablesItems, "the flags keep the values of the moment the menu opened")
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "---" : $0.title }, [
            "About Shiibar CC", "---", "Settings\u{2026}", "Setup Check\u{2026}", "---",
            "Archived", "Clear badges", "---", "Quit",
        ])
        XCTAssertFalse(menu.items[6].isEnabled, "Clear badges")
        for index in [0, 2, 3, 5, 8] {
            XCTAssertTrue(menu.items[index].isEnabled, menu.items[index].title)
        }
        for menuItem in menu.items where !menuItem.isSeparatorItem {
            XCTAssertEqual(menuItem.keyEquivalent, "", menuItem.title)
            XCTAssertTrue(menuItem.target === handler, menuItem.title)
            XCTAssertNotNil(menuItem.action, menuItem.title)
        }
        let withUnreviewed = handler.menu(for: HeaderMenu.entries(hasUnreviewed: true, hasArchived: true,
                                                                  showsArchive: false))
        XCTAssertTrue(withUnreviewed.items[6].isEnabled)
    }
}
