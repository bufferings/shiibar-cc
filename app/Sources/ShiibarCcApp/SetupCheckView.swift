// The Settings window's Setup Check tab (DESIGN.md §4.5 "Setup Check tab",
// §8.65). Shows `shiibar-cc doctor --json` (§4.4) as ✓/⚠/✗ rows in a
// "Doctor" box, plus the two checks only the running app can answer —
// notification permission and Login Item registration — in an "App" box,
// with the same boxes, headings, row padding and row lines as the General
// tab (SettingsView.swift). Judgement logic lives entirely in
// ShiibarCcCore's SetupCheckLogic (doctor stays the source of truth for its
// own checks, §4.5); this file is only the I/O (subprocess,
// UNUserNotificationCenter, SMAppService), the tab's view and `Re-run`.

import AppKit
import ShiibarCcCore
import SwiftUI

/// Runs the checks and republishes the results as two row lists, one per
/// box. When the checks run (§4.5 "Setup Check tab"):
/// - every time the tab is shown (switching back to it included), unless a
///   run is still in flight — then that run's result is what shows;
/// - `Re-run`, unless a run is in flight;
/// - never because the window became key again or Settings… was chosen.
/// A run in flight when the window closes is not stopped; its result is
/// discarded, and the next showing of the tab runs again (after that run
/// lands, if it is still in flight).
@MainActor
final class SetupCheckViewModel: ObservableObject {
    /// Runs every check and calls back on the main actor with the Doctor
    /// rows and the App rows.
    typealias Checks = (@escaping @MainActor (_ cliRows: [SetupCheckRow], _ appRows: [SetupCheckRow]) -> Void) -> Void

    @Published private(set) var cliRows: [SetupCheckRow] = []
    @Published private(set) var appRows: [SetupCheckRow] = []
    /// A run has completed and its rows are shown (before that, the Doctor
    /// box shows `No results yet.`).
    @Published private(set) var hasResults = false
    /// A run is in flight: `Re-run` is disabled and shows the progress.
    @Published private(set) var isRunning = false

    private let performChecks: Checks
    /// The run in flight was started before the window closed: its result
    /// is dropped.
    private var discardsRunInFlight = false
    /// The tab was shown while a discarded run was in flight: run again
    /// when it lands.
    private var runsAfterRunInFlight = false

    init(performChecks: @escaping Checks) {
        self.performChecks = performChecks
    }

    convenience init(
        helpersDirectory: URL?,
        notificationManager: NotificationManager,
        loginItemEnabledProvider: @escaping () -> Bool
    ) {
        self.init(performChecks: Self.liveChecks(
            helpersDirectory: helpersDirectory,
            notificationManager: notificationManager,
            loginItemEnabledProvider: loginItemEnabledProvider))
    }

    static let noResultsText = "No results yet."

    /// The tab is shown.
    func tabShown() {
        if isRunning {
            if discardsRunInFlight { runsAfterRunInFlight = true }
            return
        }
        run()
    }

    /// `Re-run`: a manual run on top of the automatic one.
    func rerun() {
        guard !isRunning else { return }
        run()
    }

    /// The Settings window is closing.
    func windowClosed() {
        runsAfterRunInFlight = false
        if isRunning { discardsRunInFlight = true }
    }

    private func run() {
        isRunning = true
        discardsRunInFlight = false
        performChecks { [weak self] cliRows, appRows in
            self?.finish(cliRows: cliRows, appRows: appRows)
        }
    }

    private func finish(cliRows: [SetupCheckRow], appRows: [SetupCheckRow]) {
        isRunning = false
        if discardsRunInFlight {
            discardsRunInFlight = false
            if runsAfterRunInFlight {
                runsAfterRunInFlight = false
                run()
            }
            return
        }
        self.cliRows = cliRows
        self.appRows = appRows
        hasResults = true
    }

    /// The real checks: `shiibar-cc doctor --json` off the main thread,
    /// then the notification permission and `SMAppService.mainApp.status`
    /// (read fresh on every run, never cached — §4.5). Doctor rows first,
    /// then the two app-side rows.
    static func liveChecks(
        helpersDirectory: URL?,
        notificationManager: NotificationManager,
        loginItemEnabledProvider: @escaping () -> Bool
    ) -> Checks {
        { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = CLIRunner.doctorJSON(helpersDirectory: helpersDirectory)
                let cliRows = SetupCheckParsing.parseDoctorJSON(result.stdout)
                Task { @MainActor in
                    notificationManager.currentPermissionState { permissionState in
                        let notificationRow = SetupCheckAppSideRows.notificationPermissionRow(state: permissionState)
                        let loginItemRow = SetupCheckAppSideRows.loginItemRow(enabled: loginItemEnabledProvider())
                        MainActor.assumeIsolated {
                            completion(cliRows, [notificationRow, loginItemRow])
                        }
                    }
                }
            }
        }
    }
}

/// The Setup Check tab: the Doctor and App boxes, then `Re-run` at the
/// right end below them (§4.5 "Setup Check tab"; window-design.html).
struct SetupCheckTab: View {
    @ObservedObject var model: SetupCheckViewModel

    static let doctorTitle = "Doctor"
    static let appTitle = "App"
    static let rerunTitle = "Re-run"

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.boxSpacing) {
            SettingsBox(title: Self.doctorTitle) {
                if model.hasResults {
                    rows(model.cliRows)
                } else {
                    // Before the first run completes (§4.5 "no results
                    // yet"): in the Doctor box, where the rows go; the App
                    // box has no rows and is not shown.
                    Text(SetupCheckViewModel.noResultsText)
                        .font(.system(size: SettingsLayout.labelFont))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(maxWidth: .infinity, minHeight: SettingsLayout.rowMinContentHeight, alignment: .leading)
                        .padding(.vertical, SettingsLayout.rowVertical)
                        .padding(.horizontal, SettingsLayout.rowHorizontal)
                }
            }
            if model.hasResults {
                SettingsBox(title: Self.appTitle) {
                    rows(model.appRows)
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button {
                    model.rerun()
                } label: {
                    // The progress shows inside the button while a run is
                    // in flight; the hidden title keeps the button's width.
                    ZStack {
                        Text(Self.rerunTitle).opacity(model.isRunning ? 0 : 1)
                        if model.isRunning {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(model.isRunning)
            }
        }
    }

    private func rows(_ rows: [SetupCheckRow]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { SettingsRowDivider() }
            SetupCheckRowView(row: row)
        }
    }
}

/// One check (window-design.html `.it` with `.ck`): the result symbol
/// (13pt bold, 16pt wide, centered; green / yellow / red for the check's
/// result — not the state colors of §3.1), then 8pt to the summary (13pt)
/// with the hint under it (11pt, secondary) when there is one. Both wrap;
/// there is no right column.
private struct SetupCheckRowView: View {
    let row: SetupCheckRow

    static let symbolWidth: CGFloat = 16
    static let symbolSpacing: CGFloat = 8

    private var symbolColor: Color {
        switch row.status {
        case .ok: return .green
        case .warn: return .yellow
        case .fail: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.symbolSpacing) {
            Text(row.status.symbol)
                .font(.system(size: SettingsLayout.labelFont, weight: .bold))
                .foregroundStyle(symbolColor)
                .frame(width: Self.symbolWidth, alignment: .center)
            VStack(alignment: .leading, spacing: SettingsLayout.labelDescriptionSpacing) {
                Text(row.summary)
                    .font(.system(size: SettingsLayout.labelFont))
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = row.hint {
                    Text(hint)
                        .font(.system(size: SettingsLayout.descriptionFont))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: SettingsLayout.rowMinContentHeight)
        .padding(.vertical, SettingsLayout.rowVertical)
        .padding(.horizontal, SettingsLayout.rowHorizontal)
    }
}
