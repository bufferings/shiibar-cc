// App entry point (DESIGN.md §4.5): an accessory-policy app whose tray icon
// is an own `NSStatusItem` opening an `NSPopover`, plus the single window
// opened from it (`MainSurfaceController`, AppKit). SwiftUI scenes host only
// the Settings window and the app menu commands. Daemon
// lifecycle, reconcile, and the first-launch-only Login Item
// auto-registration are kicked off from `applicationDidFinishLaunching`.

import AppKit
import os
import ServiceManagement
import ShiibarCcCore
import SwiftUI

@main
struct ShiibarCcMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Placeholder first scene that is never inserted into the menu bar:
        // SwiftUI opens the FIRST scene at launch when it is a `Window`
        // (measured on macOS with a throwaway harness), and this app must
        // launch with no window. The real tray icon is the controller's own
        // `NSStatusItem`.
        MenuBarExtra("Shiibar CC", isInserted: .constant(false)) {
            EmptyView()
        }

        // Settings window (§4.5/§8.26/§8.65) with its General and Setup
        // Check tabs, opened via `openWindow(id:)` from the ⌄ menu and the
        // app menu. The window's size follows its content.
        Window(SettingsWindow.title, id: SettingsWindow.id) {
            SettingsView(model: appDelegate.state.settingsWindow)
        }
        .windowResizability(.contentSize)
        // App menu and Edit menu (§4.5/§8.30/§8.41). Commands are app-wide;
        // `.commands` can only EMPTY the standard menus — `MainMenuPruner`
        // (started in `AppDelegate`, see AppMenu.swift) hides the husks.
        .commands {
            AppMenuCommands(state: appDelegate.state, menuModel: appDelegate.appMenuModel)
            RemoveStandardMenusCommands()
            RemoveStandardMenusCommands.Extra()
        }
    }
}

/// The Settings `Window` scene's stable id, shared between the scene
/// declaration above and the `openWindow(id:)` call sites.
enum SettingsWindow {
    static let id = "settings"
    /// Must match the title passed to `Window(_:id:)` above (the ⌄ menu
    /// finds the opened window by it to make it key, and
    /// `SettingsWindowModel` finds its close by it).
    static let title = "Settings"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState
    /// The deduped state the app menu observes (see `AppMenuModel` in
    /// AppMenu.swift): agent churn must not invalidate an open menu.
    let appMenuModel: AppMenuModel
    /// Keeps the menu bar down to the app menu and Edit while the app is
    /// regular (§4.5/§8.30) — see AppMenu.swift.
    private let mainMenuPruner = MainMenuPruner()
    /// The status item, the popover, the window, and the key monitor.
    /// Created after launch (it touches NSStatusBar / NSApp).
    private var surfaceController: MainSurfaceController?

    override init() {
        let bundleURL = Bundle.main.bundleURL
        let helpersDirectory: URL? = bundleURL.pathExtension == "app"
            ? bundleURL.appendingPathComponent("Contents/Helpers")
            : nil
        state = AppState(helpersDirectory: helpersDirectory)
        appMenuModel = AppMenuModel()
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // §4.5/§8.42: keep the Edit menu to its standard text verbs. These
        // two defaults suppress the system-injected items entirely —
        // verified empirically with a probe app (with the keys registered
        // before finishLaunching, "Start Dictation…" and "Emoji & Symbols"
        // never appear; without them they do). `register` is non-persistent
        // (the user's defaults DB stays clean) and launch-safe (plain
        // UserDefaults, no NSApp). AutoFill and the standard group's Delete
        // have no working suppression (probe-measured: hides and removals
        // are reverted by SwiftUI's open-time menu rebuild; three candidate
        // AutoFill defaults keys had no effect) and remain visible.
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])
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
        // The app becomes regular only while the window is open (§8.30).
        NSApp.setActivationPolicy(.accessory)
        mainMenuPruner.start()
        performFirstLaunchLoginItemAutoRegistrationIfNeeded()
        let controller = MainSurfaceController(state: state)
        surfaceController = controller
        controller.start()
        state.start()
    }

    /// Dock-icon click (and any other reopen event) while the app is
    /// regular brings the window forward (§4.5/§8.30). Reopen can only
    /// happen while the app is regular: while the window is open, or while
    /// the popover `Open in popover` opened is shown (no window to raise
    /// then; the raise does nothing). ⌘Tab needs no code here: activating
    /// the app raises its visible windows on its own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        state.raiseMainWindow()
        return false
    }

    /// Closing the last window never quits the app: it stays in the menu
    /// bar (§4.5). The answer has to be explicit because SwiftUI quits an
    /// app whose only window scene is a single `Window` when its last
    /// window closes, and that covers the AppKit main window too.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The documented Quit path is the ⌄ menu / app menu (`state.quit()`,
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
    /// turns "Start at Login" off in Settings keeps that choice across
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
