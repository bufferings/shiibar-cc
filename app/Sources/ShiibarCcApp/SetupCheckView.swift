// Setup Check window (DESIGN.md §4.5, M5 T5): opened from the ⌄ menu's
// "Setup Check…" item. Shows `shiibar-cc doctor --json` (§4.4) as a ✓/⚠/✗
// list, plus the two checks only the running app can answer — notification
// permission and Login Item registration. Judgement logic lives entirely in
// ShiibarCcCore's SetupCheckLogic (doctor stays the source of truth for its
// own checks, §4.5); this file is only the I/O (subprocess, UNUserNotification-
// Center, SMAppService) and the SwiftUI list, plus the Re-run button.

import ServiceManagement
import ShiibarCcCore
import SwiftUI

/// Runs the CLI + app-side checks and republishes the combined row list.
/// `@MainActor` because `rows`/`isRunning` drive SwiftUI and the completion
/// handlers below all hop back to the main actor before touching them.
@MainActor
final class SetupCheckViewModel: ObservableObject {
    @Published private(set) var rows: [SetupCheckRow] = []
    @Published private(set) var isRunning = false

    private let helpersDirectory: URL?
    private let notificationManager: NotificationManager
    /// `SMAppService.mainApp.status` read fresh on every run (§4.5: never
    /// cached — same rule as the ⌄ menu's own "Start at Login" checkmark,
    /// `AppState.loginItemEnabled`), injected so tests could stub it if
    /// this view model ever needs a fixture-driven test of its own.
    private let loginItemEnabledProvider: () -> Bool

    init(
        helpersDirectory: URL?,
        notificationManager: NotificationManager,
        loginItemEnabledProvider: @escaping () -> Bool
    ) {
        self.helpersDirectory = helpersDirectory
        self.notificationManager = notificationManager
        self.loginItemEnabledProvider = loginItemEnabledProvider
    }

    /// Runs every check (CLI + the two app-side ones) and republishes
    /// `rows` when all of it lands. A run already in flight is left alone
    /// (Re-run while running is a no-op, same overlap guard as manual
    /// Rescan, `AppState.runReconcile`).
    func runChecks() {
        guard !isRunning else { return }
        isRunning = true
        let helpersDirectory = helpersDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = CLIRunner.doctorJSON(helpersDirectory: helpersDirectory)
            let cliRows = SetupCheckParsing.parseDoctorJSON(result.stdout)
            Task { @MainActor [weak self] in
                self?.finishWithCLIRows(cliRows)
            }
        }
    }

    private func finishWithCLIRows(_ cliRows: [SetupCheckRow]) {
        notificationManager.currentPermissionState { [weak self] permissionState in
            guard let self else { return }
            let notificationRow = SetupCheckAppSideRows.notificationPermissionRow(state: permissionState)
            let loginItemRow = SetupCheckAppSideRows.loginItemRow(enabled: self.loginItemEnabledProvider())
            self.rows = cliRows + [notificationRow, loginItemRow]
            self.isRunning = false
        }
    }
}

struct SetupCheckView: View {
    @StateObject private var viewModel: SetupCheckViewModel

    init(helpersDirectory: URL?, notificationManager: NotificationManager, loginItemEnabledProvider: @escaping () -> Bool) {
        _viewModel = StateObject(wrappedValue: SetupCheckViewModel(
            helpersDirectory: helpersDirectory,
            notificationManager: notificationManager,
            loginItemEnabledProvider: loginItemEnabledProvider
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Setup Check")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    viewModel.runChecks()
                } label: {
                    if viewModel.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Re-run")
                    }
                }
                .disabled(viewModel.isRunning)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)

            Divider()

            if viewModel.rows.isEmpty && !viewModel.isRunning {
                Text("No results yet.")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.rows) { row in
                            SetupCheckRowView(row: row)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 420, height: 360)
        .onAppear {
            // `NSApp.activate` is required in an LSUIElement (accessory)
            // app: without it the window can open behind other apps, or
            // never gain key/focus at all (§4.5).
            NSApp.activate(ignoringOtherApps: true)
            viewModel.runChecks()
        }
    }
}

private struct SetupCheckRowView: View {
    let row: SetupCheckRow

    private var symbolColor: Color {
        switch row.status {
        case .ok: return .green
        case .warn: return .yellow
        case .fail: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(row.status.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(symbolColor)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.summary)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = row.hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
