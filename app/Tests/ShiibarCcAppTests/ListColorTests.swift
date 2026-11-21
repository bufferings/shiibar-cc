import AppKit
import ShiibarCcCore
import SwiftUI
import XCTest
@testable import ShiibarCcApp

/// The list's colors resolved in the light and the dark appearance
/// (window-design.html "implementation notes": the rule for the list
/// ground, the row frames' ground and the bands' ground). No window is
/// shown.
@MainActor
final class ListColorTests: XCTestCase {
    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor? {
        var result: NSColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        return result
    }

    private func assertSameColor(_ a: NSColor?, _ b: NSColor?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else { return XCTFail("unresolved: \(message)", file: file, line: line) }
        for (x, y) in [(a.redComponent, b.redComponent), (a.greenComponent, b.greenComponent),
                       (a.blueComponent, b.blueComponent), (a.alphaComponent, b.alphaComponent)] {
            XCTAssertEqual(x, y, accuracy: 0.002, message, file: file, line: line)
        }
    }

    /// The colors as resolved in each appearance: the list ground (light:
    /// control background + 10% system gray; dark: window background + 30%
    /// black), the row frame (light: control background; dark: white at
    /// 0.10), the band (system gray at 0.12 light / 0.08 dark).
    func testResolvedListFrameAndBandColorsInLightAndDark() {
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let expectedList: NSColor? = dark
                ? resolved(NSColor.windowBackgroundColor, name)?.blended(withFraction: 0.3, of: .black)
                : resolved(NSColor.controlBackgroundColor, name)?.blended(withFraction: 0.10, of: resolved(.systemGray, name) ?? .gray)
            assertSameColor(resolved(SurfaceColors.listBackgroundNSColor, name), expectedList?.usingColorSpace(.sRGB), "list ground \(name)")
            let expectedCard: NSColor? = dark
                ? NSColor.white.withAlphaComponent(0.10).usingColorSpace(.sRGB)
                : resolved(NSColor.controlBackgroundColor, name)
            assertSameColor(resolved(SurfaceColors.cardNSColor, name), expectedCard, "row frame \(name)")
            let band = NSColor(SurfaceColors.sectionBand)
            assertSameColor(resolved(band, name), resolved(NSColor.systemGray, name)?.withAlphaComponent(dark ? 0.08 : 0.12),
                            "band \(name)")
        }
    }

    /// The popover paints its arrow (its whole ground) with the list
    /// ground's color, in both appearances.
    func testPopoverArrowUsesTheListGround() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let view = PopoverBackgroundView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            view.appearance = NSAppearance(named: name)
            var ground: CGColor?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.updateLayer()
                ground = view.layer?.backgroundColor
            }
            let groundColor = try XCTUnwrap(ground.flatMap { NSColor(cgColor: $0) }).usingColorSpace(.sRGB)
            assertSameColor(groundColor, resolved(SurfaceColors.listBackgroundNSColor, name), "popover ground \(name)")
        }
    }
}
