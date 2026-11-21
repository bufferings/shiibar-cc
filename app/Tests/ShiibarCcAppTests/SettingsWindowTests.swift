import AppKit
import ShiibarCcCore
import SwiftUI
import XCTest
@testable import ShiibarCcApp

/// The Settings window (DESIGN.md §4.5 "Settings window", §9 "Settings
/// window dimensions" / "Settings tab row dimensions"): the General tab's
/// boxes and rows, the tabs, what a tab switch does, and the tab on every
/// open. In-memory defaults, a spy hotkey registrar, an injected
/// notification center and injected checks: no real hotkey, `doctor`,
/// notification permission or Login Item is touched, and nothing is shown
/// on screen (content is measured in a hosting view that is never put in a
/// window).
@MainActor
final class SettingsWindowTests: XCTestCase {
    private final class SpyRegistrar: GlobalHotKeyRegistering {
        var onPressed: () -> Void = {}
        func register(_ shortcut: GlobalShortcut) -> Bool { true }
        func unregister() {}
    }

    private var defaults = InMemoryDefaults()
    private var center = NotificationCenter()
    private var checkRuns = 0
    /// The installed apps the Terminal row's lookup sees, by bundle id.
    private var installedApps: [String: InstalledTerminalApp] = [:]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        defaults = InMemoryDefaults()
        center = NotificationCenter()
        checkRuns = 0
        installedApps = ["com.googlecode.iterm2": InstalledTerminalApp(shortVersion: "3.7.6")]
    }

    private func makeModel() -> SettingsWindowModel {
        let hotKey = GlobalHotKeyModel(registrar: SpyRegistrar(), defaults: defaults)
        hotKey.start()
        return SettingsWindowModel(
            general: SettingsViewModel(
                notificationManager: NotificationManager(),
                loginItemEnabledProvider: { false },
                toggleLoginItem: {},
                appearanceSetting: .system,
                setAppearance: { _ in },
                availableSoundNames: ["Glass"]),
            textSizeField: TextSizeFieldModel(store: TextSizeStore(defaults: defaults)),
            hotKey: hotKey,
            setupCheck: SetupCheckViewModel(performChecks: { [weak self] _ in self?.checkRuns += 1 }),
            resumeTerminal: ResumeTerminalSetting(
                defaults: defaults, lookup: { [weak self] in self?.installedApps[$0] }, center: center),
            center: center)
    }

    /// A window with the Settings window's title, never shown.
    private func settingsWindow(title: String = SettingsWindow.title) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = title
        return window
    }

    /// The tab content's size as the window sizes to it: 600pt wide, the
    /// height the content asks for.
    private func fittingSize(_ model: SettingsWindowModel) -> NSSize {
        let hosting = NSHostingView(rootView: SettingsTabContent(model: model)
            .frame(width: SettingsLayout.windowWidth)
            .fixedSize(horizontal: false, vertical: true))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    // MARK: - General tab layout

    /// The table in §4.5 "Settings window": two boxes, General and Sounds,
    /// the rows in order with their labels, descriptions and controls.
    func testGeneralTabBoxesRowsAndControls() {
        XCTAssertEqual(SettingsGeneralLayout.boxes.map(\.title), ["General", "Sounds"])
        XCTAssertEqual(SettingsGeneralLayout.boxes.map(\.rows), [
            [.startAtLogin, .appearance, .textSize, .globalShortcut, .terminal],
            [.muteSound, .waitingSound, .doneSound],
        ])
        let expected: [(SettingsRow, String, String, SettingsControlKind)] = [
            (.startAtLogin, "Start at Login", "Runs in the menu bar after you log in to your Mac", .toggleSwitch),
            (.appearance, "Appearance", "System follows the appearance setting of your Mac", .segmented),
            (.textSize, "Text size", "Text in the popover and the window", .numberFieldAndStepper),
            (.globalShortcut, "Global shortcut", "Shows the list from any app", .shortcutField),
            (.terminal, "Terminal", "Resume and Branch open in this terminal", .segmented),
            (.muteSound, "Mute sound", "Notifications arrive silently", .toggleSwitch),
            (.waitingSound, "Waiting sound", "Plays when a session needs your input", .popup),
            (.doneSound, "Done sound", "Plays when a session finishes responding", .popup),
        ]
        XCTAssertEqual(SettingsRow.allCases, expected.map(\.0))
        for (row, label, description, control) in expected {
            XCTAssertEqual(row.label, label)
            XCTAssertEqual(row.description, description, label)
            XCTAssertEqual(row.control, control, label)
        }
        XCTAssertEqual(TextSizeRow.label, "Text size")
        XCTAssertEqual(GlobalShortcutRow.label, "Global shortcut")
    }

    /// §9 "Settings window dimensions" and "Settings error and guidance
    /// text color".
    func testWindowDimensions() {
        XCTAssertEqual(SettingsLayout.windowWidth, 600)
        XCTAssertEqual(SettingsLayout.contentTop, 16)
        XCTAssertEqual(SettingsLayout.contentSide, 24)
        XCTAssertEqual(SettingsLayout.contentBottom, 20)
        XCTAssertEqual(SettingsLayout.boxSpacing, 14)
        XCTAssertEqual(SettingsLayout.headingToBox, 6)
        XCTAssertEqual(SettingsLayout.headingIndent, 4)
        XCTAssertEqual(SettingsLayout.boxCornerRadius, 10)
        XCTAssertEqual(SettingsLayout.rowVertical, 9)
        XCTAssertEqual(SettingsLayout.rowHorizontal, 14)
        XCTAssertEqual(SettingsLayout.rowMinContentHeight, 22)
        XCTAssertEqual(SettingsLayout.columnSpacing, 12)
        XCTAssertEqual(SettingsLayout.labelDescriptionSpacing, 2)
        XCTAssertEqual(SettingsLayout.controlColumnWidth, 240)
        XCTAssertEqual(SettingsLayout.controlColumnSpacing, 8)
        XCTAssertEqual(SettingsLayout.labelFont, 13)
        XCTAssertEqual(SettingsLayout.descriptionFont, 11)
        XCTAssertEqual(SettingsLayout.headingFont, 12)
        XCTAssertEqual(SettingsLayout.messageFont, 11)
        XCTAssertEqual(SettingsLayout.textSizeFieldWidth, 56)
        XCTAssertEqual(SettingsLayout.textSizeStepperSpacing, 4)
        for (name, hex) in [(NSAppearance.Name.aqua, (0xA0, 0x39, 0x0A)), (.darkAqua, (0xF0, 0x8A, 0x5D))] {
            var color: NSColor?
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                color = SettingsColors.messageNSColor.usingColorSpace(.sRGB)
            }
            XCTAssertEqual(color?.redComponent ?? -1, CGFloat(hex.0) / 255, accuracy: 0.001, "\(name)")
            XCTAssertEqual(color?.greenComponent ?? -1, CGFloat(hex.1) / 255, accuracy: 0.001, "\(name)")
            XCTAssertEqual(color?.blueComponent ?? -1, CGFloat(hex.2) / 255, accuracy: 0.001, "\(name)")
        }
    }

    /// The window's width is 600pt; the height follows the content: an
    /// error line under Text size's description, or a guidance line under
    /// Global shortcut's, makes it taller, and clearing the line makes it
    /// shorter again.
    func testHeightFollowsTheErrorAndGuidanceLines() {
        let model = makeModel()
        let plain = fittingSize(model)
        XCTAssertEqual(plain.width, 600)

        model.textSizeField.text = "abc"
        model.textSizeField.commit()
        XCTAssertNotNil(model.textSizeField.error)
        let withError = fittingSize(model)
        XCTAssertEqual(withError.width, 600)
        XCTAssertGreaterThan(withError.height, plain.height)

        model.textSizeField.text = "14"
        model.textSizeField.commit()
        XCTAssertNil(model.textSizeField.error)
        XCTAssertEqual(fittingSize(model).height, plain.height, accuracy: 0.5)

        model.hotKey.fieldClicked()
        model.hotKey.keyPressed(keyCode: 0x28, modifiers: [], keyName: "K")
        XCTAssertEqual(model.hotKey.recorder.hint, .addModifier)
        XCTAssertGreaterThan(fittingSize(model).height, plain.height)
        model.hotKey.recordingAbandoned()
        XCTAssertNil(model.hotKey.recorder.hint)
        XCTAssertEqual(fittingSize(model).height, plain.height, accuracy: 0.5)
    }

    // MARK: - Terminal row (§4.5 "Settings window" > Terminal)

    /// A pick is stored at once and comes back on the next launch; every
    /// choice can be picked whether or not it is installed.
    func testTerminalPickIsStoredAndRestored() {
        let model = makeModel()
        XCTAssertEqual(model.resumeTerminal.terminal, .iterm2, "first value: iTerm2 is installed")
        for terminal in [ResumeTerminal.ghostty, .appleTerminal, .iterm2, .ghostty] {
            model.resumeTerminal.select(terminal)
            XCTAssertEqual(model.resumeTerminal.terminal, terminal)
            XCTAssertEqual(defaults.string(forKey: "cc.shiibar.resumeTerminal"), terminal.rawValue)
        }
        let relaunched = ResumeTerminalSetting(defaults: defaults, lookup: { _ in nil }, center: NotificationCenter())
        XCTAssertEqual(relaunched.terminal, .ghostty, "a stored value is not decided again")
    }

    /// The reason line under the description while the chosen terminal
    /// cannot be used: it makes the window taller and goes away with a
    /// usable choice. Terminal never shows one.
    func testTerminalReasonLineFollowsTheChoice() {
        let model = makeModel()
        let plain = fittingSize(model)
        XCTAssertNil(model.resumeTerminal.availability.settingsMessage)

        model.resumeTerminal.select(.ghostty)
        XCTAssertEqual(model.resumeTerminal.availability.settingsMessage, "Ghostty is not installed")
        XCTAssertGreaterThan(fittingSize(model).height, plain.height)

        model.resumeTerminal.select(.appleTerminal)
        XCTAssertNil(model.resumeTerminal.availability.settingsMessage)
        XCTAssertEqual(fittingSize(model).height, plain.height, accuracy: 0.5)

        installedApps = [:]
        model.resumeTerminal.select(.iterm2)
        XCTAssertEqual(model.resumeTerminal.availability.settingsMessage, "iTerm2 is not installed")

        installedApps = ["com.mitchellh.ghostty": InstalledTerminalApp(shortVersion: "1.3.1")]
        model.resumeTerminal.select(.ghostty)
        XCTAssertEqual(model.resumeTerminal.availability.settingsMessage, "Ghostty 1.4.0 or later is required")
    }

    /// Showing the Settings window decides availability again (a terminal
    /// installed while the app runs shows at once).
    func testShowingTheWindowDecidesTerminalAvailabilityAgain() {
        let model = makeModel()
        model.resumeTerminal.select(.ghostty)
        XCTAssertEqual(model.resumeTerminal.availability, .notInstalled(.ghostty))
        installedApps["com.mitchellh.ghostty"] = InstalledTerminalApp(shortVersion: "1.4.0")
        XCTAssertEqual(model.resumeTerminal.availability, .notInstalled(.ghostty), "nothing decides until a trigger")
        model.windowShown()
        XCTAssertEqual(model.resumeTerminal.availability, .available)
    }

    // MARK: - Tabs

    /// §4.5 / §9: `General` then `Setup Check`, with SF Symbols that exist
    /// on the deployment target's symbol set, and the tab row's dimensions.
    func testTabsOrderSymbolsAndTabRowDimensions() {
        XCTAssertEqual(SettingsTab.allCases.map(\.title), ["General", "Setup Check"])
        for tab in SettingsTab.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil), tab.symbolName)
        }
        XCTAssertEqual(SettingsTabBarLayout.rowVertical, 6)
        XCTAssertEqual(SettingsTabBarLayout.rowHorizontal, 12)
        XCTAssertEqual(SettingsTabBarLayout.buttonSpacing, 4)
        XCTAssertEqual(SettingsTabBarLayout.buttonMinWidth, 72)
        XCTAssertEqual(SettingsTabBarLayout.buttonVertical, 6)
        XCTAssertEqual(SettingsTabBarLayout.buttonHorizontal, 8)
        XCTAssertEqual(SettingsTabBarLayout.iconSize, 18)
        XCTAssertEqual(SettingsTabBarLayout.iconNameSpacing, 3)
        XCTAssertEqual(SettingsTabBarLayout.nameFont, 11)
        XCTAssertEqual(SettingsTabBarLayout.selectedCornerRadius, 7)
        XCTAssertEqual(SettingsTabBarLayout.selectedTintOpacity, 0.16)
        XCTAssertEqual(SettingsTabBarLayout.bottomLine, 1)
    }

    /// The window opens on General every time: closing it while Setup
    /// Check is shown puts General back. Another window's close does not.
    func testEveryOpenShowsGeneral() {
        let model = makeModel()
        XCTAssertEqual(model.selectedTab, .general)
        model.select(.setupCheck)
        XCTAssertEqual(model.selectedTab, .setupCheck)

        center.post(name: NSWindow.willCloseNotification, object: settingsWindow(title: "Shiibar CC"))
        XCTAssertEqual(model.selectedTab, .setupCheck, "another window closing")

        center.post(name: NSWindow.willCloseNotification, object: settingsWindow())
        XCTAssertEqual(model.selectedTab, .general)
    }

    /// Settings… while the window is open (the ⌄ menu's and the app menu's
    /// path, `open(using:)`) asks the scene to open the Settings window and
    /// changes neither the tab nor runs the checks; the window becoming key
    /// again does neither either.
    func testSettingsWhileOpenKeepsTheTabAndRunsNothing() {
        let model = makeModel()
        model.select(.setupCheck)
        XCTAssertEqual(checkRuns, 1)
        var opened: [String] = []
        model.open { opened.append($0) }
        XCTAssertEqual(opened, [SettingsWindow.id])
        center.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow())
        XCTAssertEqual(model.selectedTab, .setupCheck)
        XCTAssertEqual(checkRuns, 1)
    }

    /// Opened again after a close, the window shows General and runs no
    /// check.
    func testSettingsAfterACloseShowsGeneral() {
        let model = makeModel()
        model.select(.setupCheck)
        center.post(name: NSWindow.willCloseNotification, object: settingsWindow())
        var opened: [String] = []
        model.open { opened.append($0) }
        XCTAssertEqual(opened, [SettingsWindow.id])
        XCTAssertEqual(model.selectedTab, .general)
        XCTAssertEqual(checkRuns, 1)
    }

    /// Opening the window (General) runs no check.
    func testOpeningOnGeneralRunsNoCheck() {
        let model = makeModel()
        XCTAssertEqual(model.selectedTab, .general)
        model.select(.general)
        XCTAssertEqual(checkRuns, 0)
    }

    /// Switching tabs applies an edited Text size value (as a focus loss
    /// does) and abandons a Global shortcut recording.
    func testSwitchingTabsAppliesTheEditedTextSizeAndAbandonsRecording() {
        let model = makeModel()
        XCTAssertEqual(model.textSizeField.size.points, 13)
        model.textSizeField.text = "16"
        model.hotKey.fieldClicked()
        XCTAssertTrue(model.hotKey.recorder.isRecording)

        model.select(.setupCheck)

        XCTAssertEqual(model.textSizeField.size.points, 16)
        XCTAssertFalse(model.hotKey.recorder.isRecording)
    }

    /// Switching tabs with an invalid edit shows the error and puts the
    /// current value back, the same rule as a focus loss.
    func testSwitchingTabsWithAnInvalidEditShowsTheError() {
        let model = makeModel()
        model.textSizeField.text = "40"
        model.select(.setupCheck)
        XCTAssertEqual(model.textSizeField.error, .outOfRange)
        XCTAssertEqual(model.textSizeField.text, "13")
        XCTAssertEqual(model.textSizeField.size.points, 13)
    }

    /// The height follows the shown tab: the Setup Check tab before any
    /// result is shorter than the General tab.
    func testHeightFollowsTheShownTab() {
        let model = makeModel()
        let general = fittingSize(model)
        model.select(.setupCheck)
        let setupCheck = fittingSize(model)
        XCTAssertEqual(setupCheck.width, 600)
        XCTAssertNotEqual(setupCheck.height, general.height)
    }
}
