// Setup Check window (DESIGN.md §4.5, M5 T5; grouped-Form look M15): opened
// from the ⌄ menu's "Setup Check…" item. Shows `shiibar-cc doctor --json`
// (§4.4) as a ✓/⚠/✗ list in a "Doctor" Form section, plus the two checks
// only the running app can answer — notification permission and Login Item
// registration — in an "App" section. Judgement logic lives entirely in
// ShiibarCcCore's SetupCheckLogic (doctor stays the source of truth for its
// own checks, §4.5); this file is only the I/O (subprocess, UNUserNotification-
// Center, SMAppService) and the SwiftUI Form, plus the Re-run button.

import AppKit
import ServiceManagement
import ShiibarCcCore
import SwiftUI

/// Runs the CLI + app-side checks and republishes the results as two row
/// lists, one per Form section (M15: "Doctor" for the CLI-sourced rows,
/// "App" for the two app-side ones). `@MainActor` because `cliRows`/
/// `appRows`/`isRunning` drive SwiftUI and the completion handlers below all
/// hop back to the main actor before touching them.
@MainActor
final class SetupCheckViewModel: ObservableObject {
    @Published private(set) var cliRows: [SetupCheckRow] = []
    @Published private(set) var appRows: [SetupCheckRow] = []
    @Published private(set) var isRunning = false

    private let helpersDirectory: URL?
    private let notificationManager: NotificationManager
    /// `SMAppService.mainApp.status` read fresh on every run (§4.5: never
    /// cached — same rule as the ⌄ menu's own "Start at Login" checkmark,
    /// `AppState.loginItemEnabled`), injected so tests could stub it if
    /// this view model ever needs a fixture-driven test of its own.
    private let loginItemEnabledProvider: () -> Bool
    /// Whether the Setup Check window is currently on screen: set when it
    /// becomes key, cleared by `willCloseNotification` — lets
    /// `noteWindowBecameKey` tell a genuine (re)open apart from a plain
    /// refocus. See `observeWindowLifecycle`.
    private var isWindowCurrentlyOpen = false
    private var windowLifecycleObservers: [NSObjectProtocol] = []

    init(
        helpersDirectory: URL?,
        notificationManager: NotificationManager,
        loginItemEnabledProvider: @escaping () -> Bool
    ) {
        self.helpersDirectory = helpersDirectory
        self.notificationManager = notificationManager
        self.loginItemEnabledProvider = loginItemEnabledProvider
        observeWindowLifecycle()
    }

    deinit {
        let observers = windowLifecycleObservers
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Triggers `runChecks()` on every genuine open of the Setup Check
    /// window, including close-then-reopen (DESIGN.md §4.5: checks must not
    /// show a stale previous run after the window was closed and reopened).
    ///
    /// `SetupCheckView.onAppear` cannot do this: verified on-device (a
    /// throwaway SwiftUI `Window(id:)` harness, same toolchain) that a
    /// `Window` scene's hosted view — and therefore its `@StateObject` —
    /// survives close/reopen. `onAppear` fires exactly once per app run and
    /// never again on reopen, the same "hosted view stays alive across
    /// open/close" behavior already documented (and worked around the same
    /// way) in `AppState.observeDropdownOpen` for the dropdown panel.
    ///
    /// `NSWindow.didBecomeKeyNotification` DOES fire reliably on reopen
    /// (verified in both a plain harness and an accessory + MenuBarExtra
    /// harness matching this app's shape), but it also fires on a plain
    /// refocus (e.g. switching to another app and back) without the window
    /// ever closing — so it can't be the sole trigger. The "window closed"
    /// signal is `NSWindow.willCloseNotification`: it fires exactly on
    /// genuine close (both the red button and the ⌘W/performClose route —
    /// verified in the accessory harness) and never on refocus.
    /// `didResignKeyNotification` is deliberately NOT used for this: in the
    /// accessory configuration the window can resign key long before it is
    /// closed (with `isVisible` still `true`), and if it is closed while no
    /// longer key, no resign fires at close time at all — an
    /// `isVisible`-at-resign heuristic left `isWindowCurrentlyOpen` stuck
    /// `true` and permanently blocked re-runs (owner-observed on the real
    /// app, then reproduced in the harness).
    ///
    /// So: `didBecomeKey` + "was not already open" = genuine (re)open →
    /// `runChecks()`; refocus while open stays suppressed (§4.5 M16
    /// constraint). The in-flight guard in `runChecks()` still applies on
    /// top of this, so rapid close/reopen can't run two checks in parallel
    /// either.
    private func observeWindowLifecycle() {
        let center = NotificationCenter.default
        let becameKeyObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title == SetupCheckWindow.title,
                  let self else { return }
            Task { @MainActor in
                self.noteWindowBecameKey()
            }
        }
        let willCloseObserver = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title == SetupCheckWindow.title,
                  let self else { return }
            Task { @MainActor in
                self.isWindowCurrentlyOpen = false
            }
        }
        windowLifecycleObservers = [becameKeyObserver, willCloseObserver]
    }

    private func noteWindowBecameKey() {
        guard !isWindowCurrentlyOpen else { return } // still open — a refocus, not a (re)open
        isWindowCurrentlyOpen = true
        runChecks()
    }

    /// Runs every check (CLI + the two app-side ones) and republishes
    /// `cliRows`/`appRows` when all of it lands. A run already in flight is left alone
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
            // Combined order is unchanged from before the split (doctor rows
            // first, then the two app-side rows) — only the publishing shape
            // changed, to match the two Form sections (M15).
            self.cliRows = cliRows
            self.appRows = [notificationRow, loginItemRow]
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
        // A grouped `Form` (DESIGN.md §4.5: same look as the Settings
        // window, M14) — two sections, "Doctor" for the CLI-sourced rows
        // and "App" for the two app-side ones. The window's title bar
        // already reads "Setup Check", so no in-content heading is drawn
        // (same reasoning as Settings dropping its own heading, M14).
        VStack(spacing: 0) {
            Form {
                if viewModel.cliRows.isEmpty && viewModel.appRows.isEmpty && !viewModel.isRunning {
                    Text("No results yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Section("Doctor") {
                        ForEach(viewModel.cliRows) { row in
                            SetupCheckRowView(row: row)
                        }
                    }

                    Section("App") {
                        ForEach(viewModel.appRows) { row in
                            SetupCheckRowView(row: row)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Re-run lives outside the Form, in a persistent footer, so it
            // stays put while the sections above scroll (§4.5).
            HStack {
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
            .padding(12)
        }
        // Height is sized so the normal case (5 doctor rows + 2 app rows,
        // each with a hint line) is fully visible without scrolling —
        // scrolling is only a safety net for unusually long content.
        // Estimate: 7 two-line rows x ~44pt (13pt summary + 11pt hint +
        // grouped-Form row padding) = ~308, two section headers plus form
        // insets and the inter-section gap ~ +100, footer (divider +
        // Re-run + 12pt padding) ~ +52, and the rest is slack for one or
        // two wrapped summary/hint lines. Trailing blank card background
        // is acceptable; a forced scroll in the normal case is not.
        .frame(width: 420, height: 540)
        .onAppear {
            // `NSApp.activate` is required in an LSUIElement (accessory)
            // app: without it the window can open behind other apps, or
            // never gain key/focus at all (§4.5). Running the checks
            // themselves is NOT done here — `onAppear` only fires once per
            // app run for this `Window` scene (M16, see
            // `SetupCheckViewModel.observeWindowLifecycle`), so that's
            // handled by the window becoming key instead, which fires on
            // every open including close-then-reopen.
            NSApp.activate(ignoringOtherApps: true)
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
