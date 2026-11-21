import AppKit
import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The tray image is set only when what it depicts changes (DESIGN.md §4.5
/// "visual source of truth", §8.51): the state, the menu bar's darkness and
/// the dot's resolved color. The status item is replaced by closures, the
/// color resolver is a stub, and the system-colors notification is posted
/// on an injected center.
@MainActor
final class TrayImageUpdaterTests: XCTestCase {
    private let orange = ResolvedRGBA(red: 1, green: 0.58, blue: 0, alpha: 1)
    private let blue = ResolvedRGBA(red: 0, green: 0.48, blue: 1, alpha: 1)
    private let purple = ResolvedRGBA(red: 0.6, green: 0.2, blue: 0.8, alpha: 1)

    private var state = TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: nil)
    private var accent: ResolvedRGBA!
    private var images: [NSImage] = []
    private var rendered: [(TrayIconState, Bool, ResolvedRGBA?)] = []
    private var resolvedValues: [ResolvedRGBA?] = []
    private var center = NotificationCenter()

    override func setUp() {
        super.setUp()
        state = TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: nil)
        accent = blue
        images = []
        rendered = []
        resolvedValues = []
        center = NotificationCenter()
    }

    private func makeUpdater(renderSpy: Bool = false) -> TrayImageUpdater {
        TrayImageUpdater(
            state: { [unowned self] in self.state },
            appearance: { NSAppearance(named: .aqua) },
            setImage: { [unowned self] in self.images.append($0) },
            resolve: { [unowned self] dot, _ in
                let value: ResolvedRGBA? = switch dot {
                case .waiting: self.orange
                case .unreviewed: self.accent
                case nil: nil
                }
                self.resolvedValues.append(value)
                return value
            },
            render: { [unowned self] state, dark, color in
                if renderSpy { self.rendered.append((state, dark, color)) }
                return TrayIconRenderer.render(state: state, darkMenuBar: dark, dotColor: color)
            },
            center: center)
    }

    func testNoDotIsATemplateImageAndADotIsNot() {
        let updater = makeUpdater()
        updater.refresh()
        XCTAssertEqual(images.count, 1)
        XCTAssertTrue(images[0].isTemplate)
        state = TrayIconState(glyph: .waiting, dim: Rollup.normalDim, dot: .waiting)
        updater.refresh()
        XCTAssertEqual(images.count, 2)
        XCTAssertFalse(images[1].isTemplate)
    }

    func testTheSameKindAndColorIsNotSetAgain() {
        let updater = makeUpdater()
        state = TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: .unreviewed)
        for _ in 0..<5 { updater.refresh() }
        XCTAssertEqual(images.count, 1)
    }

    func testAChangedDotKindIsSetAgain() {
        let updater = makeUpdater()
        state = TrayIconState(glyph: .waiting, dim: Rollup.normalDim, dot: .waiting)
        updater.refresh()
        state = TrayIconState(glyph: .waiting, dim: Rollup.normalDim, dot: .unreviewed)
        updater.refresh()
        XCTAssertEqual(images.count, 2)
        state = TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: nil)
        updater.refresh()
        XCTAssertEqual(images.count, 3)
    }

    /// The system colors changing (the accent color setting) re-resolves
    /// the dot: a different color is set again, the same color is not.
    func testSystemColorsChangeSetsTheImageAgainOnlyWhenTheColorChanged() {
        let updater = makeUpdater()
        state = TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: .unreviewed)
        updater.refresh()
        XCTAssertEqual(images.count, 1)
        center.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        XCTAssertEqual(images.count, 1, "same color")
        accent = purple
        center.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        XCTAssertEqual(images.count, 2, "the accent color changed")
        withExtendedLifetime(updater) {}
    }

    /// The color compared and the color drawn are the one value resolved
    /// for the refresh.
    func testTheResolvedColorIsTheOneDrawn() {
        let updater = makeUpdater(renderSpy: true)
        state = TrayIconState(glyph: .waiting, dim: Rollup.normalDim, dot: .waiting)
        updater.refresh()
        state = TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: .unreviewed)
        updater.refresh()
        XCTAssertEqual(rendered.count, 2)
        XCTAssertEqual(rendered.map(\.2), [orange, blue])
        XCTAssertEqual(resolvedValues, [orange, blue])
    }
}
