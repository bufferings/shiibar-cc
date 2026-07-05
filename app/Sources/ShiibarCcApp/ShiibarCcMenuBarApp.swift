// App entry point (DESIGN.md §4.5): MenuBarExtra in the "window" style
// (custom dropdown, not a standard NSMenu), an accessory-policy app (no
// Dock icon, no regular app menu — DESIGN.md §8.4 keeps the menu bar's verb
// set to focus/back/rescan/mute/quit only). Daemon lifecycle, reconcile,
// and Login Items self-registration are kicked off from
// `applicationDidFinishLaunching`.

import AppKit
import ServiceManagement
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
        registerLoginItemIfPossible()
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

    /// Register as a Login Item (macOS 13+ `SMAppService`) so the app (and
    /// therefore the daemon, §8.8) starts automatically at login. Only
    /// meaningful once bundled as a `.app` (`install.sh`'s job, §4.5); in a
    /// `swift run` dev build this is a no-op.
    private func registerLoginItemIfPossible() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}
