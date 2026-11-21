import XCTest
@testable import ShiibarCcCore

final class TrayImageGateTests: XCTestCase {
    private let base = TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: nil)
    private let blue = ResolvedRGBA(red: 0.0, green: 0.48, blue: 1.0, alpha: 1)
    private let orange = ResolvedRGBA(red: 1.0, green: 0.58, blue: 0.0, alpha: 1)

    func testFirstCallRenders() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false, dotColor: nil))
    }

    func testRepeatedSameInputsDoNotRender() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: true, dotColor: nil))
        XCTAssertFalse(gate.shouldRender(state: base, darkMenuBar: true, dotColor: nil))
        XCTAssertFalse(gate.shouldRender(state: base, darkMenuBar: true, dotColor: nil))
    }

    func testGlyphChangeRenders() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false, dotColor: nil))
        let waiting = TrayIconState(glyph: .waiting, dim: Rollup.idleDim, dot: nil)
        XCTAssertTrue(gate.shouldRender(state: waiting, darkMenuBar: false, dotColor: nil))
    }

    func testIdleToWorkingRenders() {
        var gate = TrayImageGate()
        let working = TrayIconState(glyph: .working, dim: Rollup.normalDim, dot: nil)
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false, dotColor: nil))
        XCTAssertFalse(gate.shouldRender(state: base, darkMenuBar: false, dotColor: nil))
        XCTAssertTrue(gate.shouldRender(state: working, darkMenuBar: false, dotColor: nil))
        XCTAssertFalse(gate.shouldRender(state: working, darkMenuBar: false, dotColor: nil))
    }

    func testDimChangeRenders() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false, dotColor: nil))
        let dimmer = TrayIconState(glyph: .idle, dim: Rollup.noAgentsDim, dot: nil)
        XCTAssertTrue(gate.shouldRender(state: dimmer, darkMenuBar: false, dotColor: nil))
    }

    func testDotAppearingRenders() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false, dotColor: nil))
        let dotted = TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: .unreviewed)
        XCTAssertTrue(gate.shouldRender(state: dotted, darkMenuBar: false, dotColor: blue))
    }

    func testDarkMenuBarChangeRenders() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false, dotColor: nil))
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: true, dotColor: nil))
    }

    func testChangingBackRendersAgain() {
        var gate = TrayImageGate()
        let dotted = TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: .unreviewed)
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false, dotColor: nil))
        XCTAssertTrue(gate.shouldRender(state: dotted, darkMenuBar: false, dotColor: blue))
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false, dotColor: nil))
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: true, dotColor: nil))
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false, dotColor: nil))
    }

    func testLongRunOfIdenticalInputsRendersOnce() {
        // Models the appearance observation re-firing after every image
        // assignment: only the first call may assign an image.
        var gate = TrayImageGate()
        let renders = (0..<1_000).filter { _ in gate.shouldRender(state: base, darkMenuBar: true, dotColor: nil) }.count
        XCTAssertEqual(renders, 1)
    }

    /// The dot's kind is part of what the image depicts: waiting (orange)
    /// and unreviewed (accent color) are different images.
    func testDotKindChangeRenders() {
        var gate = TrayImageGate()
        let waiting = TrayIconState(glyph: .waiting, dim: Rollup.normalDim, dot: .waiting)
        let unreviewed = TrayIconState(glyph: .waiting, dim: Rollup.normalDim, dot: .unreviewed)
        XCTAssertTrue(gate.shouldRender(state: waiting, darkMenuBar: false, dotColor: orange))
        XCTAssertFalse(gate.shouldRender(state: waiting, darkMenuBar: false, dotColor: orange))
        XCTAssertTrue(gate.shouldRender(state: unreviewed, darkMenuBar: false, dotColor: blue))
        XCTAssertFalse(gate.shouldRender(state: unreviewed, darkMenuBar: false, dotColor: blue))
    }

    /// The resolved color is compared too: a change of the accent color
    /// setting with the same dot kind is a new image; the same resolved
    /// value is not.
    func testResolvedColorChangeRenders() {
        var gate = TrayImageGate()
        let dotted = TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: .unreviewed)
        let purple = ResolvedRGBA(red: 0.6, green: 0.2, blue: 0.8, alpha: 1)
        XCTAssertTrue(gate.shouldRender(state: dotted, darkMenuBar: false, dotColor: blue))
        XCTAssertFalse(gate.shouldRender(state: dotted, darkMenuBar: false, dotColor: blue))
        XCTAssertTrue(gate.shouldRender(state: dotted, darkMenuBar: false, dotColor: purple))
        XCTAssertFalse(gate.shouldRender(state: dotted, darkMenuBar: false, dotColor: purple))
    }
}
