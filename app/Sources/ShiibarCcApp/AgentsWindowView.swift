// Agents window (DESIGN.md §4.5 "the agent list window", M26): the ⌄ menu's "Open
// as Window" opens the same agent list as the dropdown, but as an ordinary
// window that stays open until closed (⌘W / the red traffic-light button)
// instead of closing on outside click. Content is fully shared with the
// dropdown via `AgentListView` (M26 T1); this file supplies only the
// window-side container context (`AgentsWindowViewModel`, M26 T3), the
// regular-app switch tied to this window's existence (§8.30, M27 T1), plus
// the `NSApp.activate` LSUIElement requirement every other `Window` scene
// in this app needs (Settings / Setup Check, M14/M5 T5).

import AppKit
import ShiibarCcCore
import SwiftUI

/// Owns the Agents window's own visibility flag and elapsed-time base
/// (§4.5 "the agent list window", M26 T3) — kept separate from the dropdown's
/// `AppState.dropdownOpenedAt` / `isDropdownOpen` so the two containers
/// never disturb each other when both happen to be open at once. Row ORDER
/// needs no per-container state: both containers order live from `agents`
/// by the immutable `created_at` key on every render (§8.31).
///
/// Window lifecycle tracking follows `SetupCheckViewModel.observeWindowLifecycle`
/// (M16): `didBecomeKeyNotification` + "not already visible" = genuine
/// (re)open, `willCloseNotification` = genuine close, both filtered by this
/// window's stable title. This is deliberately NOT the dropdown's
/// `didResignKeyNotification` + class-name filter (`AppState.observeDropdownOpen`)
/// — that suits a panel that visually disappears the instant it loses key.
/// This is an ordinary titled window that can lose key while remaining
/// fully on screen (e.g. switching to another app and back), and §4.5 wants
/// the spinner running the whole time it's visible, not just while key.
@MainActor
final class AgentsWindowViewModel: ObservableObject {
    @Published private(set) var openedAt: Int64 = Int64(Date().timeIntervalSince1970)
    @Published private(set) var isVisible = false

    private weak var state: AppState?
    private var refreshTimer: Timer?
    private var windowLifecycleObservers: [NSObjectProtocol] = []

    init(state: AppState) {
        self.state = state
        observeWindowLifecycle()
    }

    deinit {
        let observers = windowLifecycleObservers
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        refreshTimer?.invalidate()
    }

    private func observeWindowLifecycle() {
        let center = NotificationCenter.default
        let becameKeyObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title == AgentsWindow.title,
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
                  window.title == AgentsWindow.title,
                  let self else { return }
            let frameHeight = Double(window.frame.height)
            Task { @MainActor in
                self.noteWindowClosed(frameHeight: frameHeight)
            }
        }
        // Height memory (§4.5/§8.32, M29 T2): remember the height the user
        // dragged the window to. `didEndLiveResize` fires only for USER
        // resizes (not for the programmatic `setFrame` height application),
        // so this is exactly "the user decided a height".
        let liveResizeObserver = center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == AgentsWindow.title else { return }
            let frameHeight = Double(window.frame.height)
            Task { @MainActor in
                AgentsWindowHeightMemory.save(frameHeight)
            }
        }
        windowLifecycleObservers = [becameKeyObserver, willCloseObserver, liveResizeObserver]
    }

    /// Genuine (re)open — not a plain refocus while still visible (same
    /// "was not already open" guard as `SetupCheckViewModel.noteWindowBecameKey`,
    /// M16): re-settle the elapsed-time base, re-evaluate the
    /// notification-permission warning row (§4.5: the denied determination
    /// is also re-evaluated every time the window opens — only at open,
    /// unlike the elapsed base's own every-60s refresh below), and start
    /// the periodic refresh timer for as long as the window stays visible.
    private func noteWindowBecameKey() {
        guard !isVisible else { return }
        isVisible = true
        switchToRegularApp()
        refreshElapsedBase()
        state?.notificationManager.refreshPermissionStatus()
        startRefreshTimer()
    }

    private func noteWindowClosed(frameHeight: Double) {
        isVisible = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        // Height memory, belt and braces (§4.5, M29 T2): also persist at
        // close, so "reopen at the same height" holds even when the height
        // was never live-resized this session (e.g. the first-open natural
        // height, or SwiftUI's own frame restoration across launches — our
        // stored value is applied on every open and must therefore always
        // reflect the last state the user saw).
        AgentsWindowHeightMemory.save(frameHeight)
        // §4.5/§8.30 (M27 T1): the Dock icon, ⌘Tab entry and app menu
        // exist only while the Agents window does — back to the resident
        // accessory the moment it closes. No activation dance is needed on
        // the way down: the system hands focus (and the menu bar) to
        // another app by itself.
        NSApp.setActivationPolicy(.accessory)
    }

    /// While the Agents window exists the app is a regular app — Dock,
    /// ⌘Tab, app menu (§4.5/§8.30, M27 T1). Only the Agents window flips
    /// this: Settings / Setup Check opened on their own never reach this
    /// code (this view model's observers are title-filtered).
    ///
    /// Ordering measured on-device (macOS 14 harness, M27): after flipping
    /// an already-active app to `.regular` — and "Open as Window" always
    /// happens while active, the user just clicked the dropdown — the menu
    /// bar keeps showing the PREVIOUS app's menus even though
    /// `NSApp.isActive` is true. Neither activate-after-policy (a no-op
    /// while active), deactivate+activate, nor a next-turn activate
    /// refreshes it. The one reliable order: set the policy, hand
    /// activation to another app (the Dock — always running, shows no menu
    /// bar of its own), then take it back a beat later.
    private func switchToRegularApp() {
        NSApp.setActivationPolicy(.regular)
        if let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock").first {
            dock.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            // No Dock process to bounce through (not seen in practice) —
            // degrade to a plain activate: the app still becomes regular,
            // at worst the menu bar lags until the next app switch.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Re-settle the elapsed-time base (§4.5: at open, then every
    /// `AgentListWindowRefresh.intervalSeconds` while visible — the
    /// dropdown's "reopen to refresh" idea, automated because this
    /// container lives longer; display is minute-granularity, so no
    /// per-second ticking).
    private func refreshElapsedBase() {
        openedAt = Int64(Date().timeIntervalSince1970)
    }

    /// Runs only while the window is visible (§4.5: the timer runs only
    /// while the window is visible — the same thrift as the tray's working
    /// animation timer, `AppState.refreshWorkingAnimationTimer`).
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: AgentListWindowRefresh.intervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshElapsedBase()
            }
        }
    }
}

/// UserDefaults-backed memory of the Agents window's FRAME height
/// (§4.5/§8.32, M29 T2: the resident container's size is the user's
/// decision — remembered, unlike the position, which is a rule: always
/// under the icon). Written by `AgentsWindowViewModel` (live resize +
/// close), read by `VMenuHandler.placeAgentsWindow` when applying the
/// frame on open. `stored()` returns 0 when nothing is saved —
/// `AgentListHeights.agentsWindowHeightToApply` treats that as "first
/// open, use the natural fallback".
enum AgentsWindowHeightMemory {
    static let key = "cc.shiibar.agentsWindowHeight"

    @MainActor static func save(_ frameHeight: Double) {
        UserDefaults.standard.set(frameHeight, forKey: key)
    }

    @MainActor static func stored() -> Double {
        UserDefaults.standard.double(forKey: key)
    }
}

struct AgentsWindowView: View {
    @ObservedObject var state: AppState
    @StateObject private var windowState: AgentsWindowViewModel

    init(state: AppState) {
        self.state = state
        _windowState = StateObject(wrappedValue: AgentsWindowViewModel(state: state))
    }

    var body: some View {
        AgentListView(
            state: state,
            container: AgentListContainer(
                kind: .window,
                openedAt: windowState.openedAt,
                isActive: windowState.isVisible,
                screenVisibleHeight: nil // M29 T2: no screen cap — the window's height rules the list
            )
        )
        // Vertical-only resizability (§4.5/§8.32, M29 T2): with the scene's
        // `windowResizability(.contentSize)`, the window's min/max track
        // THESE content bounds — width pinned at 340 (min == max), height
        // free from ~3 rows up (the traffic-light band is added on top by
        // AppKit automatically). Measured on-device (M29 harness): this
        // yields `styleMask.resizable` with contentMin (340, 150+band) and
        // contentMax (340, inf) — the user can drag height only — and a
        // programmatic `setFrame` (the height apply in
        // `VMenuHandler.placeAgentsWindow`) sticks, with AppKit itself
        // clamping anything below the minimum. Removing the `.contentSize`
        // resizability instead was measured to unbound BOTH axes (the
        // window even opens at the wrong width), so it stays.
        .frame(
            minWidth: 340,
            maxWidth: 340,
            minHeight: CGFloat(AgentListHeights.agentsWindowMinContentHeight),
            maxHeight: .infinity
        )
        // No safe-area tricks (§4.5, M26 T4): `.hiddenTitleBar` reserves
        // the former title bar as a top safe-area inset (28pt, measured
        // on-device via a standalone harness on macOS 14), so the shared
        // list lays out below that slim band — the traffic lights keep the
        // band to themselves and the content keeps the exact same layout
        // the dropdown has, chip in its usual top-left spot. The band is
        // also what makes top-edge dragging work: it is still the window's
        // title-bar drag area, standard AppKit behavior.
        .onAppear {
            // `NSApp.activate` is required in an LSUIElement (accessory)
            // app: without it the window can open behind other apps, or
            // never gain key/focus at all (§4.5), same requirement as
            // Setup Check / Settings. Belt-and-braces only — the primary
            // trigger is at the "Open as Window" click site itself
            // (AgentListView's VMenuHandler.openAsWindow calls
            // `NSApp.activate` on every click); `onAppear` fires only once
            // per app run for this `Window` scene (M16 precedent, see
            // `SetupCheckViewModel.observeWindowLifecycle`).
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
