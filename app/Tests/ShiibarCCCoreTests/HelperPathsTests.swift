import XCTest
@testable import ShiibarCCCore

final class HelperPathsTests: XCTestCase {
    func testDevelopmentFallsBackToBareNameForPathLookup() {
        XCTAssertEqual(HelperPathResolver.resolvedPath(for: .shiibarCc, helpersDirectory: nil), "shiibar-cc")
        XCTAssertEqual(HelperPathResolver.resolvedPath(for: .shiibarCcd, helpersDirectory: nil), "shiibar-ccd")
    }

    func testBundledUsesAbsolutePathUnderHelpersDirectory() {
        // A synthetic path under a temp dir — never a machine-specific real
        // install path, per CLAUDE.md's portability rule.
        let helpers = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("shiibar-cc.app/Contents/Helpers")
        XCTAssertEqual(
            HelperPathResolver.resolvedPath(for: .shiibarCc, helpersDirectory: helpers),
            helpers.appendingPathComponent("shiibar-cc").path
        )
    }
}
