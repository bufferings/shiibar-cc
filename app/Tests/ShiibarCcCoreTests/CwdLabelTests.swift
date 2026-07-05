// Ported from shiibar-cc-client::label's test cases (Rust) — the app must
// agree exactly with the CLI's label formatting (DESIGN.md §4.5).

import XCTest
@testable import ShiibarCcCore

final class CwdLabelTests: XCTestCase {
    func testHomeRelativePathGetsTildeAndLastTwoComponents() {
        XCTAssertEqual(
            CwdLabel.format(cwd: "/Users/example/projects/shiibar", home: "/Users/example"),
            "projects/shiibar"
        )
    }

    func testHomeRelativePathWithOneComponentShowsWhatItHas() {
        XCTAssertEqual(
            CwdLabel.format(cwd: "/Users/example/shiibar", home: "/Users/example"),
            "shiibar"
        )
    }

    func testExactlyHomeDirectoryIsJustTilde() {
        XCTAssertEqual(
            CwdLabel.format(cwd: "/Users/example", home: "/Users/example"),
            "~"
        )
    }

    func testNonHomePathUsesLastTwoComponentsWithNoPrefix() {
        XCTAssertEqual(
            CwdLabel.format(cwd: "/opt/build/shiibar/worktree", home: "/Users/example"),
            "shiibar/worktree"
        )
    }

    func testNoHomeKnownFallsBackToLastTwoComponents() {
        XCTAssertEqual(
            CwdLabel.format(cwd: "/opt/build/shiibar/worktree", home: nil),
            "shiibar/worktree"
        )
    }

    func testSiblingPathSharingAPrefixIsNotTreatedAsHomeRelative() {
        // "/Users/example-other" starts with "/Users/example" as a string,
        // but not at a path component boundary.
        XCTAssertEqual(
            CwdLabel.format(cwd: "/Users/example-other/x", home: "/Users/example"),
            "example-other/x"
        )
    }
}
