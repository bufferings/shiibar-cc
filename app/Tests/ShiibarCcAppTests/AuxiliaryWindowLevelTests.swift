import AppKit
import XCTest
@testable import ShiibarCcApp

/// Settings, Setup Check and the About panel float while the main window's
/// pin is ON and the window is open, so they open in front of the pinned
/// window, and are at the normal level otherwise (DESIGN.md §4.5 "pin (Keep
/// on Top)"). No window is created.
@MainActor
final class AuxiliaryWindowLevelTests: XCTestCase {
    /// Floating only with the pin ON and the main window open; the pin OFF
    /// or the window closed (the popover form included) is normal.
    func testLevelFollowsThePinAndTheOpenWindow() {
        XCTAssertEqual(AuxiliaryWindowLevel.level(keepOnTop: true, windowOpen: true), .floating)
        XCTAssertEqual(AuxiliaryWindowLevel.level(keepOnTop: true, windowOpen: false), .normal)
        XCTAssertEqual(AuxiliaryWindowLevel.level(keepOnTop: false, windowOpen: true), .normal)
        XCTAssertEqual(AuxiliaryWindowLevel.level(keepOnTop: false, windowOpen: false), .normal)
    }

    func testOnlySettingsSetupCheckAndTheAboutPanelAreAuxiliary() {
        XCTAssertTrue(AuxiliaryWindowLevel.isAuxiliary(title: SettingsWindow.title, isAboutPanel: false))
        XCTAssertTrue(AuxiliaryWindowLevel.isAuxiliary(title: SetupCheckWindow.title, isAboutPanel: false))
        XCTAssertTrue(AuxiliaryWindowLevel.isAuxiliary(title: "", isAboutPanel: true))
        XCTAssertFalse(AuxiliaryWindowLevel.isAuxiliary(title: MainSurfaceController.windowTitle, isAboutPanel: false),
                       "the main window's level is the pin's own rule")
        XCTAssertFalse(AuxiliaryWindowLevel.isAuxiliary(title: "", isAboutPanel: false),
                       "untitled windows such as the popover's are left alone")
    }
}
