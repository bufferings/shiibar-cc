import AppKit
import XCTest
@testable import ShiibarCcApp

/// The header row's buttons (DESIGN.md §4.5 "header row") and the ⌄ menu
/// (§4.5 "⌄ menu", §8.61). The menu is built as an `NSMenu` without being
/// shown, so nothing reaches the screen.
@MainActor
final class HeaderRowAndMenuTests: XCTestCase {
    // MARK: - Header row

    func testHeaderRowButtonOrderPerSurface() {
        XCTAssertEqual(HeaderRowButton.buttons(for: .popover), [.openInWindow, .menu])
        XCTAssertEqual(HeaderRowButton.buttons(for: .window), [.openInPopover, .pin, .menu])
    }

    func testHeaderRowTooltips() {
        XCTAssertEqual(HeaderRowButton.openInWindow.tooltip, "Open in window")
        XCTAssertEqual(HeaderRowButton.openInPopover.tooltip, "Open in popover")
        XCTAssertEqual(HeaderRowButton.pin.tooltip, "Keep on top")
        XCTAssertNil(HeaderRowButton.menu.tooltip)
        // Refresh is a ⌄ menu item and ⌘R, never a header button.
        for surface in [MainSurface.popover, .window] {
            let tooltips = HeaderRowButton.buttons(for: surface).compactMap(\.tooltip)
            XCTAssertFalse(tooltips.contains { $0.contains("Refresh") }, "\(surface)")
        }
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

    func testMenuItemsAndOrder() {
        let entries = HeaderMenu.entries(isRefreshing: false, hasUnreviewed: true)
        XCTAssertEqual(titles(entries), [
            "About Shiibar CC", "---", "Settings\u{2026}", "Setup Check\u{2026}", "---",
            "Refresh", "Clear badges", "---", "Quit",
        ])
        for entry in entries {
            if case .item(let item) = entry {
                XCTAssertTrue(item.isEnabled, item.title)
                XCTAssertEqual(item.commandKey, item.command == .refresh ? "r" : nil, item.title)
            }
        }
    }

    func testRefreshItemWhileRefreshing() {
        let entries = HeaderMenu.entries(isRefreshing: true, hasUnreviewed: true)
        let refresh = item(entries, .refresh)
        XCTAssertEqual(refresh?.title, "Refreshing\u{2026}")
        XCTAssertEqual(refresh?.isEnabled, false)
        XCTAssertEqual(refresh?.commandKey, "r", "the shortcut stays shown")
        XCTAssertEqual(titles(entries).count, 9, "the structure does not change")
    }

    func testClearBadgesIsDisabledWithNothingUnreviewed() {
        XCTAssertEqual(item(HeaderMenu.entries(isRefreshing: false, hasUnreviewed: false), .clearBadges)?.isEnabled, false)
        XCTAssertEqual(item(HeaderMenu.entries(isRefreshing: false, hasUnreviewed: true), .clearBadges)?.isEnabled, true)
    }

    // MARK: - ⌄ menu as built

    func testBuiltMenuShowsCommandRAndTheEnabledFlags() {
        let handler = HeaderMenuHandler(controller: nil)
        let menu = handler.menu(for: HeaderMenu.entries(isRefreshing: true, hasUnreviewed: false))
        XCTAssertFalse(menu.autoenablesItems, "the flags keep the values of the moment the menu opened")
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "---" : $0.title }, [
            "About Shiibar CC", "---", "Settings\u{2026}", "Setup Check\u{2026}", "---",
            "Refreshing\u{2026}", "Clear badges", "---", "Quit",
        ])
        let refresh = menu.items[5]
        XCTAssertEqual(refresh.keyEquivalent, "r")
        XCTAssertEqual(refresh.keyEquivalentModifierMask, [.command])
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertFalse(menu.items[6].isEnabled, "Clear badges")
        for index in [0, 2, 3, 8] {
            XCTAssertTrue(menu.items[index].isEnabled, menu.items[index].title)
            XCTAssertEqual(menu.items[index].keyEquivalent, "", menu.items[index].title)
        }
        for menuItem in menu.items where !menuItem.isSeparatorItem {
            XCTAssertTrue(menuItem.target === handler, menuItem.title)
            XCTAssertNotNil(menuItem.action, menuItem.title)
        }

        let idle = handler.menu(for: HeaderMenu.entries(isRefreshing: false, hasUnreviewed: true))
        XCTAssertEqual(idle.items[5].title, "Refresh")
        XCTAssertTrue(idle.items[5].isEnabled)
        XCTAssertEqual(idle.items[5].action, #selector(HeaderMenuHandler.refresh(_:)))
        XCTAssertTrue(idle.items[6].isEnabled)
    }
}
