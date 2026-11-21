import ShiibarCcCore
import SwiftUI
import XCTest
@testable import ShiibarCcApp

/// The Setup Check tab's runs (DESIGN.md §4.5 "Setup Check tab"). The
/// checks are injected: each run is recorded and completed by the test, so
/// no `doctor`, notification permission or Login Item is touched.
@MainActor
final class SetupCheckTabTests: XCTestCase {
    private typealias Completion = @MainActor ([SetupCheckRow], [SetupCheckRow]) -> Void
    private var pending: [Completion] = []

    private func makeModel() -> SetupCheckViewModel {
        pending = []
        return SetupCheckViewModel(performChecks: { [weak self] completion in self?.pending.append(completion) })
    }

    private func row(_ id: String) -> SetupCheckRow {
        SetupCheckRow(id: id, status: .ok, summary: "\(id) is fine", hint: nil)
    }

    private func completeNext(cli: [String], app: [String] = ["notifications", "login-item"]) {
        guard !pending.isEmpty else { return XCTFail("no run in flight") }
        let completion = pending.removeFirst()
        completion(cli.map(row), app.map(row))
    }

    func testShowingTheTabRunsEveryTime() {
        let model = makeModel()
        XCTAssertEqual(pending.count, 0, "nothing runs before the tab is shown")
        model.tabShown()
        XCTAssertEqual(pending.count, 1)
        completeNext(cli: ["daemon"])
        model.tabShown()
        XCTAssertEqual(pending.count, 1, "switching back runs again")
    }

    func testShowingTheTabWhileARunIsInFlightStartsNoSecondRun() {
        let model = makeModel()
        model.tabShown()
        model.tabShown()
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(model.isRunning)
    }

    /// `Re-run` is disabled (and the model ignores it) while a run is in
    /// flight, the first run included; afterwards it runs again.
    func testRerunIsDisabledWhileRunning() {
        let model = makeModel()
        model.tabShown()
        XCTAssertTrue(model.isRunning, "Re-run is disabled during the first run")
        model.rerun()
        XCTAssertEqual(pending.count, 1)
        completeNext(cli: ["daemon"])
        XCTAssertFalse(model.isRunning)
        model.rerun()
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(model.isRunning)
    }

    /// Before the first run completes there are no results (`No results
    /// yet.` in the Doctor box); during a later run the previous rows stay.
    func testNoResultsBeforeTheFirstRunAndPreviousRowsDuringLaterRuns() {
        let model = makeModel()
        XCTAssertFalse(model.hasResults)
        model.tabShown()
        XCTAssertFalse(model.hasResults)
        XCTAssertEqual(SetupCheckViewModel.noResultsText, "No results yet.")
        completeNext(cli: ["daemon", "hooks"])
        XCTAssertTrue(model.hasResults)
        XCTAssertEqual(model.cliRows.map(\.id), ["daemon", "hooks"])
        XCTAssertEqual(model.appRows.map(\.id), ["notifications", "login-item"])

        model.rerun()
        XCTAssertTrue(model.isRunning)
        XCTAssertTrue(model.hasResults)
        XCTAssertEqual(model.cliRows.map(\.id), ["daemon", "hooks"], "the previous rows stay while running")
        completeNext(cli: ["daemon"])
        XCTAssertEqual(model.cliRows.map(\.id), ["daemon"])
    }

    /// A run in flight when the window closes is not stopped, and its
    /// result is discarded.
    func testClosingTheWindowDiscardsTheRunInFlight() {
        let model = makeModel()
        model.tabShown()
        model.windowClosed()
        completeNext(cli: ["daemon"])
        XCTAssertFalse(model.hasResults)
        XCTAssertTrue(model.cliRows.isEmpty)
        XCTAssertFalse(model.isRunning)
        model.tabShown()
        XCTAssertEqual(pending.count, 1, "the next showing runs again")
    }

    /// The tab shown again while the discarded run is still in flight:
    /// that run's result is still discarded, and a new run starts when it
    /// lands.
    func testShowingTheTabAgainWhileADiscardedRunIsInFlightRunsAfterIt() {
        let model = makeModel()
        model.tabShown()
        model.windowClosed()
        model.tabShown()
        XCTAssertEqual(pending.count, 1, "no second run while one is in flight")
        XCTAssertTrue(model.isRunning)
        completeNext(cli: ["stale"])
        XCTAssertFalse(model.hasResults, "the discarded run's result is not shown")
        XCTAssertEqual(pending.count, 1, "a new run starts")
        XCTAssertTrue(model.isRunning)
        completeNext(cli: ["fresh"])
        XCTAssertEqual(model.cliRows.map(\.id), ["fresh"])
    }

    /// Switching to General while a run is in flight does not stop it; its
    /// result shows.
    func testSwitchingAwayKeepsTheRun() {
        let center = NotificationCenter()
        let defaults = InMemoryDefaults()
        let setupCheck = makeModel()
        final class Registrar: GlobalHotKeyRegistering {
            var onPressed: () -> Void = {}
            func register(_ shortcut: GlobalShortcut) -> Bool { true }
            func unregister() {}
        }
        let window = SettingsWindowModel(
            general: SettingsViewModel(
                notificationManager: NotificationManager(), loginItemEnabledProvider: { false },
                toggleLoginItem: {}, appearanceSetting: .system, setAppearance: { _ in },
                availableSoundNames: ["Glass"]),
            textSizeField: TextSizeFieldModel(store: TextSizeStore(defaults: defaults)),
            hotKey: GlobalHotKeyModel(registrar: Registrar(), defaults: defaults),
            setupCheck: setupCheck,
            resumeTerminal: ResumeTerminalSetting(defaults: defaults, lookup: { _ in nil }, center: center),
            center: center)
        window.select(.setupCheck)
        window.select(.general)
        completeNext(cli: ["daemon"])
        XCTAssertEqual(setupCheck.cliRows.map(\.id), ["daemon"])
        window.select(.setupCheck)
        XCTAssertEqual(pending.count, 1, "showing the tab again runs again")
    }
}
