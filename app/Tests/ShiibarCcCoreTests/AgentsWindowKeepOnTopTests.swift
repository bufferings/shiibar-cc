import XCTest
@testable import ShiibarCcCore

final class AgentsWindowKeepOnTopTests: XCTestCase {
    func testDefaultIsOff() {
        // DESIGN.md §4.5/§8.33: Keep on Top defaults to OFF — floating is
        // only ever the user's explicit choice (§8.30 rejected it as a
        // default). `UserDefaults.bool(forKey:)` returns false for a
        // missing key, so the absent-value read matches this by
        // construction; this test pins the constant the app reads.
        XCTAssertFalse(AgentsWindowKeepOnTop.defaultEnabled)
    }
}
