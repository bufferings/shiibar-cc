import XCTest
@testable import ShiibarCcCore

final class HomeRelativePathTests: XCTestCase {
    func testUnderHomeCollapsesToTilde() {
        XCTAssertEqual(
            HomeRelativePath.format("/Users/example/Documents/blog", home: "/Users/example"),
            "~/Documents/blog"
        )
    }

    func testExactlyHomeIsTilde() {
        XCTAssertEqual(HomeRelativePath.format("/Users/example", home: "/Users/example"), "~")
    }

    func testOutsideHomeIsAbsolute() {
        XCTAssertEqual(HomeRelativePath.format("/opt/build/x", home: "/Users/example"), "/opt/build/x")
    }

    func testSiblingSharingPrefixIsNotHomeRelative() {
        XCTAssertEqual(
            HomeRelativePath.format("/Users/example-other/x", home: "/Users/example"),
            "/Users/example-other/x"
        )
    }

    func testNoHomeReturnsAbsolute() {
        XCTAssertEqual(HomeRelativePath.format("/Users/example/x", home: nil), "/Users/example/x")
    }
}
