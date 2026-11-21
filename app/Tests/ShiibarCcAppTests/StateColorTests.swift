import AppKit
import ShiibarCcCore
import SwiftUI
import XCTest
@testable import ShiibarCcApp

/// The two state colors in the list (DESIGN.md §3.1, §4.5 "Running rows",
/// §9 "state colors"): the waiting symbol is `systemOrange`, working and
/// idle carry no color, the unreviewed dot is `controlAccentColor`; the
/// Running mark uses the same two colors.
@MainActor
final class StateColorTests: XCTestCase {
    func testWaitingSymbolIsOrangeAndTheOthersHaveNoColor() {
        XCTAssertEqual(RowSymbolView.statusTintNSColor(for: .waiting), NSColor.systemOrange)
        XCTAssertNil(RowSymbolView.statusTintNSColor(for: .working))
        XCTAssertNil(RowSymbolView.statusTintNSColor(for: .idle))
    }

    func testUnreviewedDotIsTheAccentColor() {
        XCTAssertEqual(RowSymbolView.unreviewedDotNSColor, NSColor.controlAccentColor)
    }

    func testRunningMarkAndTrayDotUseTheStateColors() {
        XCTAssertEqual(SurfaceColors.stateDot(.waiting), Color(nsColor: .systemOrange))
        XCTAssertEqual(SurfaceColors.stateDot(.unreviewed), Color(nsColor: .controlAccentColor))
        XCTAssertEqual(TrayDotColor.nsColor(for: .waiting), NSColor.systemOrange)
        XCTAssertEqual(TrayDotColor.nsColor(for: .unreviewed), NSColor.controlAccentColor)
    }

    /// The tray dot's color resolves to concrete sRGB components under the
    /// given appearance; no dot resolves to nil.
    func testTrayDotColorResolvesUnderTheAppearance() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var expected: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                expected = NSColor.systemOrange.usingColorSpace(.sRGB)
            }
            let resolved = try XCTUnwrap(TrayDotColor.resolve(.waiting, appearance: appearance))
            XCTAssertEqual(resolved.red, Double(expected?.redComponent ?? -1), accuracy: 1e-6, "\(name)")
            XCTAssertEqual(resolved.green, Double(expected?.greenComponent ?? -1), accuracy: 1e-6, "\(name)")
            XCTAssertEqual(resolved.blue, Double(expected?.blueComponent ?? -1), accuracy: 1e-6, "\(name)")
            XCTAssertNotNil(TrayDotColor.resolve(.unreviewed, appearance: appearance))
            XCTAssertNil(TrayDotColor.resolve(nil, appearance: appearance))
        }
    }
}
