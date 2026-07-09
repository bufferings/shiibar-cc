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

        // Setup Check window (§4.5, M5 T5), opened via `openWindow(id:)`
        // from the ⌄ menu (DropdownView.VMenuHandler.openSetupCheck). A
        // plain `Window` scene (macOS 13+) works cleanly alongside
        // MenuBarExtra — unlike the dropdown, this is a regular titled
        // window, not a custom panel, so it needs none of the dropdown's
        // hand-rolled open/close machinery (it does, however, need the same
        // NSWindow-notification trick for re-running its checks on reopen —
        // see `SetupCheckViewModel.observeWindowLifecycle`, M16).
        Window(SetupCheckWindow.title, id: SetupCheckWindow.id) {
            SetupCheckView(
                helpersDirectory: appDelegate.state.helpersDirectory,
                notificationManager: appDelegate.state.notificationManager,
                loginItemEnabledProvider: { appDelegate.state.loginItemEnabled }
            )
        }
        .windowResizability(.contentSize)

        // Settings window (§4.5/§8.26, M14 T2), opened the same way as
        // Setup Check above (DropdownView.VMenuHandler.openSettings). It
        // replaced the ⌄ menu's old Settings submenu (Start at Login / Mute
        // Banners / Mute Sound) with this one action item.
        Window("Settings", id: SettingsWindow.id) {
            SettingsView(
                notificationManager: appDelegate.state.notificationManager,
                loginItemEnabledProvider: { appDelegate.state.loginItemEnabled },
                toggleLoginItem: { appDelegate.state.toggleLoginItem() },
                appearanceSetting: appDelegate.state.appearanceSetting,
                setAppearance: { appDelegate.state.setAppearanceSetting($0) }
            )
        }
        .windowResizability(.contentSize)

        // Agents window (§4.5 "the agent list window", M26): the ⌄ menu's "Open as
        // Window" (AgentListView's VMenuHandler.openAsWindow) opens this —
        // same shared list content as the dropdown (`AgentListView`), an
        // ordinary window that stays open until closed instead of closing
        // on outside click. `windowResizability(.contentSize)` matches the
        // dropdown's fixed width (340) and scrolling list (maxHeight 360),
        // same pattern as Setup Check / Settings above.
        //
        // `.hiddenTitleBar` (§4.5, M26 T4): hides the title-bar CHROME
        // only. The traffic-light buttons stay, in the slim former-title-
        // bar band at the top, and the shared list lays out below that
        // band with the exact same layout the dropdown has (SwiftUI
        // reserves the band as a top safe-area inset, so no per-container
        // layout difference is needed). Measured on-device (standalone
        // harness, macOS 14): the style keeps `.titled` in the styleMask,
        // keeps all three standard buttons, and still sets `NSWindow.title`
        // to the scene title below (only `titleVisibility` goes hidden) —
        // so the title-based window lookup (`VMenuHandler.openAsWindow`),
        // the lifecycle filter (`AgentsWindowViewModel`), and Mission
        // Control's listing keep working unchanged; the band also remains
        // the window's standard title-bar drag area.
        Window(AgentsWindow.title, id: AgentsWindow.id) {
            AgentsWindowView(state: appDelegate.state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        // App menu (§4.5/§8.30, M27 T2), visible while the Agents window
        // has the app in regular mode (AgentsWindowViewModel, M27 T1).
        // Commands are app-wide; they're declared on this scene because the
        // menu exists exactly as long as this window does. `.commands` can
        // only EMPTY the standard menus — `MainMenuPruner` (started in
        // `AppDelegate`, see AppMenu.swift) hides the leftover husks.
        .commands {
            AppMenuCommands(state: appDelegate.state)
            RemoveStandardMenusCommands()
            RemoveStandardMenusCommands.Extra()
        }
    }
}

/// The Setup Check `Window` scene's stable id, shared between the scene
/// declaration above and `openWindow(id:)` call site in DropdownView.
enum SetupCheckWindow {
    static let id = "setup-check"
    /// Must match the title passed to `Window(_:id:)` above — used by
    /// `SetupCheckViewModel.observeWindowLifecycle` (M16) to filter the
    /// global `NSWindow` open/close notifications down to just this window,
    /// the same title-filter idea as `AppState.observeDropdownOpen`'s
    /// class-name filter for the dropdown panel.
    static let title = "Setup Check"
}

/// The Settings `Window` scene's stable id (M14 T2), shared between the
/// scene declaration above and `openWindow(id:)` call site in DropdownView.
enum SettingsWindow {
    static let id = "settings"
}

/// The Agents `Window` scene's stable id/title (§4.5 "the agent list window", M26),
/// shared between the scene declaration above, the `openWindow(id:)` +
/// title-filter resolution in `AgentListView`'s `VMenuHandler.openAsWindow`,
/// and `AgentsWindowViewModel`'s window-lifecycle title filter — the same
/// title-filter idea `SetupCheckWindow.title` uses for
/// `SetupCheckViewModel.observeWindowLifecycle` (M16).
enum AgentsWindow {
    static let id = "agents"
    static let title = "Agents"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState
    /// Keeps the menu bar down to the app menu alone while the app is
    /// regular (§4.5/§8.30, M27 T2) — see AppMenu.swift.
    private let mainMenuPruner = MainMenuPruner()

    override init() {
        let bundleURL = Bundle.main.bundleURL
        let helpersDirectory: URL? = bundleURL.pathExtension == "app"
            ? bundleURL.appendingPathComponent("Contents/Helpers")
            : nil
        state = AppState(helpersDirectory: helpersDirectory)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `scripts/dev-uninstall.sh` launches the app with this flag to
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

        // Menu-bar-only at launch: no Dock icon, no app menu (§4.5/§8.4).
        // The app becomes regular only while the Agents window exists
        // (AgentsWindowViewModel.switchToRegularApp, §8.30/M27 T1).
        NSApp.setActivationPolicy(.accessory)
        mainMenuPruner.start()
        performFirstLaunchLoginItemAutoRegistrationIfNeeded()
        state.start()
    }

    /// Dock-icon click (and any other reopen event) while the app is
    /// regular brings the Agents window forward (§4.5/§8.30, M27 T1).
    /// Reopen can only happen while the app is regular, and the app is
    /// regular exactly while the Agents window exists — so the target is
    /// always that window. ⌘Tab needs no code here: activating the app
    /// raises its visible windows on its own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let window = NSApp.windows.first(where: { $0.title == AgentsWindow.title }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        return false
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
    /// restarts. Only meaningful once bundled as a `.app` (`dev-install.sh`'s
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
