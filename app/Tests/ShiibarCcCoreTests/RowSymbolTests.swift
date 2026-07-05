import XCTest
@testable import ShiibarCcCore

final class RowSymbolTests: XCTestCase {
    func testIdleMapsToTheEmptyCircleSymbol() {
        XCTAssertEqual(RowSymbol.kind(for: .idle), .idle)
    }

    func testWaitingMapsToTheCirclePlusBangSymbol() {
        XCTAssertEqual(RowSymbol.kind(for: .waiting), .waiting)
    }

    func testWorkingMapsToTheSpinnerSymbol() {
        XCTAssertEqual(RowSymbol.kind(for: .working), .working)
    }

    func testUnknownStatusHasNoSymbol() {
        // Forward-compat fallback (§4.2/§4.5): a status this build doesn't
        // recognize isn't drawn as any of the three known symbols.
        XCTAssertNil(RowSymbol.kind(for: .unknown))
    }
}
