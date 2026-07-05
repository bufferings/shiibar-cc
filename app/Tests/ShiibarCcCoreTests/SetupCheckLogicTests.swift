// DESIGN.md §4.4 / §4.5 (M5 T5): parsing `shiibar-cc doctor --json` output
// and building the two app-only rows. Fixture JSON strings stand in for the
// real CLI (this module never shells out — SetupCheckView does that).

import XCTest
@testable import ShiibarCcCore

final class SetupCheckLogicTests: XCTestCase {
    func testParsesOneRowPerCheckPreservingOrderAndFields() {
        let json = """
        {"checks":[
            {"id":"daemon","status":"fail","summary":"daemon not reachable at /tmp/x.sock: connection refused","hint":"start it with `shiibar-ccd --foreground`"},
            {"id":"hooks","status":"ok","summary":"hooks configured in /Users/example/.claude/settings.json","hint":null},
            {"id":"path","status":"warn","summary":"shiibar-cc is not on PATH","hint":"hooks/report.sh needs it"}
        ]}
        """
        let rows = SetupCheckParsing.parseDoctorJSON(json)
        XCTAssertEqual(rows.map(\.id), ["daemon", "hooks", "path"])
        XCTAssertEqual(rows[0].status, .fail)
        XCTAssertEqual(rows[0].hint, "start it with `shiibar-ccd --foreground`")
        XCTAssertEqual(rows[1].status, .ok)
        XCTAssertNil(rows[1].hint)
        XCTAssertEqual(rows[2].status, .warn)
        XCTAssertEqual(rows[2].summary, "shiibar-cc is not on PATH")
    }

    func testEmptyChecksArrayParsesToNoRows() {
        XCTAssertEqual(SetupCheckParsing.parseDoctorJSON(#"{"checks":[]}"#), [])
    }

    func testUnrecognizedStatusStringDefaultsToWarnRatherThanFailingToParse() {
        // Forward-compat: a future CLI version's new status value must not
        // make the whole row (or the whole window) disappear.
        let json = #"{"checks":[{"id":"future","status":"info","summary":"something new","hint":null}]}"#
        let rows = SetupCheckParsing.parseDoctorJSON(json)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, .warn)
    }

    func testMalformedJSONYieldsASingleFailRowInsteadOfCrashingOrReturningNothing() {
        for malformed in ["", "not json", "{\"checks\":", "{}"] {
            let rows = SetupCheckParsing.parseDoctorJSON(malformed)
            XCTAssertEqual(rows.count, 1, "input: \(malformed)")
            XCTAssertEqual(rows[0].status, .fail, "input: \(malformed)")
        }
    }

    func testStatusSymbols() {
        XCTAssertEqual(SetupCheckStatus.ok.symbol, "✓")
        XCTAssertEqual(SetupCheckStatus.warn.symbol, "⚠")
        XCTAssertEqual(SetupCheckStatus.fail.symbol, "✗")
    }

    // ---- app-side rows (notification permission / Login Item, §4.5) ----

    func testNotificationPermissionRowByState() {
        XCTAssertEqual(
            SetupCheckAppSideRows.notificationPermissionRow(state: .authorized).status,
            .ok
        )
        let denied = SetupCheckAppSideRows.notificationPermissionRow(state: .denied)
        XCTAssertEqual(denied.status, .fail)
        XCTAssertNotNil(denied.hint)
        let notDetermined = SetupCheckAppSideRows.notificationPermissionRow(state: .notDetermined)
        XCTAssertEqual(notDetermined.status, .warn)
        XCTAssertNotNil(notDetermined.hint)
    }

    func testLoginItemRowByEnabledFlag() {
        let enabled = SetupCheckAppSideRows.loginItemRow(enabled: true)
        XCTAssertEqual(enabled.status, .ok)
        XCTAssertNil(enabled.hint)
        let disabled = SetupCheckAppSideRows.loginItemRow(enabled: false)
        XCTAssertEqual(disabled.status, .warn)
        XCTAssertNotNil(disabled.hint)
    }
}
