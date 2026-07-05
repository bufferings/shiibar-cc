// App entry point (DESIGN.md §4.5): MenuBarExtra in the "window" style
// (custom dropdown, not a standard NSMenu), an accessory-policy app (no
// Dock icon, no regular app menu — DESIGN.md §8.4 keeps the menu bar's verb
// set to focus/back/rescan/mute/quit only). Daemon lifecycle, reconcile,
// and the first-launch-only Login Item auto-registration are kicked off
// from `applicationDidFinishLaunching`.

import AppKit
import os
import ServiceManagement
import ShiibarCcCore
import SwiftUI

@main
struct ShiibarCcMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            DropdownView(state: appDelegate.state)
        } label: {
            // The label must receive the observable AppState itself, not a
            // precomputed TrayIconState value: SwiftUI only re-evaluates
            // this closure when something it observes changes, and a plain
            // value snapshot observes nothing — that froze the tray at its
            // launch-time rendering (seen on-device). TrayIconView holds it
            // as @ObservedObject and derives the icon state per render.
            TrayIconView(state: appDelegate.state)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState

    override init() {
        let bundleURL = Bundle.main.bundleURL
        let helpersDirectory: URL? = bundleURL.pathExtension == "app"
            ? bundleURL.appendingPathComponent("Contents/Helpers")
            : nil
        state = AppState(helpersDirectory: helpersDirectory)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `scripts/uninstall.sh` launches the app with this flag to
        // deregister the Login Item before deleting the `.app` bundle —
        // `SMAppService.unregister()` only works from inside the still-
        // installed bundle, so it can't be done from the shell script
        // directly. Exits immediately without becoming a menu bar app.
        if CommandLine.arguments.contains("--unregister-login-item") {
            if Bundle.main.bundleURL.pathExtension == "app" {
                try? SMAppService.mainApp.unregister()
            }
            NSApp.terminate(nil)
            return
        }

        // Menu-bar-only: no Dock icon, no app menu (§4.5/§8.4).
        NSApp.setActivationPolicy(.accessory)
        performFirstLaunchLoginItemAutoRegistrationIfNeeded()
        state.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The documented Quit path is the dropdown's ⌄ menu (`state.quit()`,
        // which waits for the daemon's shutdown ack before calling
        // `terminate(nil)`, §8.8). This covers any other termination route
        // (e.g. system logout) with a best-effort, non-blocking shutdown
        // request instead of re-entering that same sequence.
        state.bestEffortShutdownDaemon()
        return .terminateNow
    }

    /// UserDefaults key recording that the first-launch auto-registration
    /// check has already run (DESIGN.md §4.5, M5 T3). Once set, it is never
    /// cleared — that's what lets a user's later "Start at Login" OFF
    /// choice survive restarts instead of being overwritten on next launch.
    private static let didAutoRegisterLoginItemKey = "cc.shiibar.didAutoRegisterLoginItem"

    /// Register as a Login Item (macOS 13+ `SMAppService`) so the app (and
    /// therefore the daemon, §8.8) starts automatically at login — but only
    /// as a **first-launch-only** auto-registration: it records that the
    /// check ran (regardless of outcome) and never repeats it, so a user who later
    /// turns "Start at Login" off via the ⌄ menu keeps that choice across
    /// restarts. Only meaningful once bundled as a `.app` (`install.sh`'s
    /// job, §4.5); in a `swift run` dev build this is a no-op and the flag
    /// is never recorded, so the check re-runs on the next bundled launch.
    private func performFirstLaunchLoginItemAutoRegistrationIfNeeded() {
        let defaults = UserDefaults.standard
        let didAutoRegisterAlready = defaults.bool(forKey: Self.didAutoRegisterLoginItemKey)
        let runningFromBundle = Bundle.main.bundleURL.pathExtension == "app"
        guard runningFromBundle, !didAutoRegisterAlready else { return }

        let currentlyEnabled = SMAppService.mainApp.status == .enabled
        if LoginItemAutoRegistration.shouldAutoRegister(
            didAutoRegisterAlready: didAutoRegisterAlready,
            runningFromBundle: runningFromBundle,
            currentlyEnabled: currentlyEnabled
        ) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                // §4.5's "don't swallow failures" rule: this is a
                // best-effort convenience registration, not user-initiated,
                // so no alert UI — just log it (same pattern as
                // CLIRunner's subprocess failures).
                loginItemLog.error(
                    "first-launch auto-register failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        // Recorded unconditionally once the bundled first-launch check has
        // run, whether register() fired, threw, or was skipped because the
        // Login Item was already enabled — the gate is "did we check", not
        // "did register() succeed".
        defaults.set(true, forKey: Self.didAutoRegisterLoginItemKey)
    }
}

/// os_log sink for Login Item auto-registration diagnostics. Same
/// subsystem/category convention as `CLIRunner`'s `subprocessLog`.
///   log show --last 1h --predicate 'subsystem == "cc.shiibar.menubar" AND category == "login-item"'
private let loginItemLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.shiibar.menubar",
    category: "login-item"
)
