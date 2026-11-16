import XCTest
@testable import ShiibarCcCore

final class TrayImageGateTests: XCTestCase {
    private let base = TrayIconState(glyph: .idle, dim: Rollup.idleDim, hasUnreviewedDot: false)

    func testFirstCallRenders() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false))
    }

    func testRepeatedSameInputsDoNotRender() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: true))
        XCTAssertFalse(gate.shouldRender(state: base, darkMenuBar: true))
        XCTAssertFalse(gate.shouldRender(state: base, darkMenuBar: true))
    }

    func testGlyphChangeRenders() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false))
        let waiting = TrayIconState(glyph: .waiting, dim: Rollup.idleDim, hasUnreviewedDot: false)
        XCTAssertTrue(gate.shouldRender(state: waiting, darkMenuBar: false))
    }

    func testIdleToWorkingRenders() {
        var gate = TrayImageGate()
        let working = TrayIconState(glyph: .working, dim: Rollup.normalDim, hasUnreviewedDot: false)
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false))
        XCTAssertFalse(gate.shouldRender(state: base, darkMenuBar: false))
        XCTAssertTrue(gate.shouldRender(state: working, darkMenuBar: false))
        XCTAssertFalse(gate.shouldRender(state: working, darkMenuBar: false))
    }

    func testDimChangeRenders() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false))
        let dimmer = TrayIconState(glyph: .idle, dim: Rollup.noAgentsDim, hasUnreviewedDot: false)
        XCTAssertTrue(gate.shouldRender(state: dimmer, darkMenuBar: false))
    }

    func testUnreviewedDotChangeRenders() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false))
        let dotted = TrayIconState(glyph: .idle, dim: Rollup.idleDim, hasUnreviewedDot: true)
        XCTAssertTrue(gate.shouldRender(state: dotted, darkMenuBar: false))
    }

    func testDarkMenuBarChangeRenders() {
        var gate = TrayImageGate()
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false))
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: true))
    }

    func testChangingBackRendersAgain() {
        var gate = TrayImageGate()
        let dotted = TrayIconState(glyph: .idle, dim: Rollup.idleDim, hasUnreviewedDot: true)
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false))
        XCTAssertTrue(gate.shouldRender(state: dotted, darkMenuBar: false))
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false))
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: true))
        XCTAssertTrue(gate.shouldRender(state: base, darkMenuBar: false))
    }

    func testLongRunOfIdenticalInputsRendersOnce() {
        // Models the appearance observation re-firing after every image
        // assignment: only the first call may assign an image.
        var gate = TrayImageGate()
        let renders = (0..<1_000).filter { _ in gate.shouldRender(state: base, darkMenuBar: true) }.count
        XCTAssertEqual(renders, 1)
    }
}
