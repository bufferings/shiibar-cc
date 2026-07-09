import AppKit
import XCTest
@testable import ShiibarCcCore

final class AppearanceSettingTests: XCTestCase {
    func testDefaultIsSystem() {
        // DESIGN.md §4.5 Settings > General: default System = follow the OS.
        XCTAssertEqual(AppearanceSetting.defaultSetting, .system)
    }

    func testPopupOrderIsSystemLightDark() {
        // `allCases` drives the Settings popup order — the default first.
        XCTAssertEqual(AppearanceSetting.allCases, [.system, .light, .dark])
        XCTAssertEqual(
            AppearanceSetting.allCases.map(\.displayName),
            ["System", "Light", "Dark"]
        )
    }

    func testRawValueRoundTripsForPersistence() {
        // UserDefaults persistence goes through `rawValue` (same pattern as
        // `SortMode`): every case must survive a store/load round trip.
        for setting in AppearanceSetting.allCases {
            XCTAssertEqual(AppearanceSetting(rawValue: setting.rawValue), setting)
        }
    }

    func testUnknownStoredStringFallsBackToNil() {
        // A corrupt/unknown stored value must not crash — the app falls
        // back to `defaultSetting` via `??` at the read site.
        XCTAssertNil(AppearanceSetting(rawValue: "sepia"))
    }

    func testAppearanceNamesMatchAppKitConstants() {
        // The Core target is Foundation-only, so the NSAppearance.Name
        // values are stored as plain strings — this test (which CAN import
        // AppKit) pins them to the real constants so a typo can't silently
        // apply no appearance.
        XCTAssertNil(AppearanceSetting.system.nsAppearanceNameRawValue)
        XCTAssertEqual(
            AppearanceSetting.light.nsAppearanceNameRawValue,
            NSAppearance.Name.aqua.rawValue
        )
        XCTAssertEqual(
            AppearanceSetting.dark.nsAppearanceNameRawValue,
            NSAppearance.Name.darkAqua.rawValue
        )
        // And the two non-nil names must actually resolve to appearances.
        for setting in AppearanceSetting.allCases {
            guard let name = setting.nsAppearanceNameRawValue else { continue }
            XCTAssertNotNil(NSAppearance(named: NSAppearance.Name(name)))
        }
    }
}
