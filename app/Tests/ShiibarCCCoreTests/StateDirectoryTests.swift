import XCTest
@testable import ShiibarCCCore

final class StateDirectoryTests: XCTestCase {
    func testOverrideEnvVarWins() {
        let root = StateDirectory.resolveRoot(environment: [
            "SHIIBAR_CC_STATE_DIR": "/tmp/example-state-dir",
            "HOME": "/Users/example",
        ])
        XCTAssertEqual(root, "/tmp/example-state-dir")
    }

    func testDefaultsToHomeLocalStateShiibarCc() {
        let root = StateDirectory.resolveRoot(environment: ["HOME": "/Users/example"])
        XCTAssertEqual(root, "/Users/example/.local/state/shiibar-cc")
    }

    func testMissingHomeAndOverrideResolvesToNil() {
        XCTAssertNil(StateDirectory.resolveRoot(environment: [:]))
    }

    func testSocketPathIsRootPlusSockFile() {
        XCTAssertEqual(StateDirectory.socketPath(root: "/tmp/x"), "/tmp/x/shiibar-ccd.sock")
    }

    func testDaemonLogPathIsRootPlusLogFile() {
        XCTAssertEqual(StateDirectory.daemonLogPath(root: "/tmp/x"), "/tmp/x/shiibar-ccd.log")
    }
}
