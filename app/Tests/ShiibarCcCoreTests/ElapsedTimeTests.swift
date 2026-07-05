import XCTest
@testable import ShiibarCcCore

final class ElapsedTimeTests: XCTestCase {
    func testFormatsSecondsMinutesHoursAndDays() {
        XCTAssertEqual(ElapsedTime.format(seconds: 5), "5s")
        XCTAssertEqual(ElapsedTime.format(seconds: 120), "2m")
        XCTAssertEqual(ElapsedTime.format(seconds: 3600), "1h")
        XCTAssertEqual(ElapsedTime.format(seconds: 90_000), "1d")
    }

    func testNegativeSecondsClampToZero() {
        XCTAssertEqual(ElapsedTime.format(seconds: -5), "0s")
    }
}
