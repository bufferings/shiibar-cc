// App menu (DESIGN.md §4.5 "the menu bar shows the app menu and Edit" /
// §8.30): while the window is open the app is a regular app and shows the
// app menu and the Edit menu at the top of the screen. App menu: About
// Shiibar CC / - / Settings… (⌘,) / - / Close Window (⌘W; closes the
// popover while it is key) / - / Quit Shiibar CC (⌘Q) — only the items a
// macOS app keeps in its standard places (§4.5, §8.54). Every item except
// Close Window behaves exactly like its ⌄-menu namesake.
// The same menu object also exists while only the popover shows (the app
// stays accessory, so the menu bar is not drawn), which keeps the Edit and
// app-menu shortcuts working there (§4.5 "popover").
//
// Two mechanisms cooperate (both measured on-device, macOS 14 harness, M27):
//  - `.commands` (below) REPLACES the standard command groups, which
//    empties the File/Edit/Format/View/Window/Help menus but cannot remove
//    the menus themselves — SwiftUI leaves empty husks plus system-injected
//    Edit items (AutoFill / Start Dictation / Emoji & Symbols), and stacked
//    separators where replaced-empty app-menu groups used to be.
//  - `MainMenuPruner` (bottom) therefore HIDES everything but the app menu
//    and Edit (§8.41 — standard text shortcuts need Edit's key equivalents)
//    (and the surplus separators). Hiding, not removing, is load-bearing:
//    removed items were re-added synchronously by every commands
//    invalidation — including one landing while the user had the menu open,
//    which closed it (a submenu-hover bug) — while hidden items keep
//    SwiftUI's structure intact so invalidations reconfigure in place with
//    zero churn. See `prune()` for the measurements.

import AppKit
import Combine
import ShiibarCcCore
import SwiftUI

/// The menu-facing state, re-published ONLY when a value the menu actually
/// renders genuinely changes: with the Commands observing `AppState`
/// directly, EVERY `@Published` change — notably the `agents` array
/// churning on each hook report — invalidates the commands content, and a
/// commands invalidation landing while a submenu is open closes it on the
/// spot. The menu renders exactly one value — Close Window's enabled
/// state — so only genuine changes to it may invalidate it.
@MainActor
final class AppMenuModel: ObservableObject {
    /// Whether ⌘W currently has something to close (§4.5/§8.40: Close
    /// Window is disabled when there is no closable window — e.g. every
    /// window minimized while the app stays regular). The popover's window
    /// counts while it is key (Close Window then closes the popover). Tracked off the
    /// NSWindow key notifications, sampled a tick later so the resign case
    /// reads the NEXT key window, and deduped like everything else here.
    ///
    /// Starts FALSE — the launch-time truth (no windows exist yet) — and is
    /// never read from global app state in init: this model is constructed
    /// inside `AppDelegate.init`, which runs during the App struct's body
    /// evaluation, BEFORE NSApplication exists. Reading the implicitly
    /// unwrapped `NSApp` there trapped at every launch (the same
    /// init-time-global lesson as `NotificationManager`'s lazy
    /// `UNUserNotificationCenter`).
    @Published private(set) var hasClosableWindow: Bool

    private var subscriptions: Set<AnyCancellable> = []

    /// `keyWindowProvider` is only ever invoked from NSWindow notification
    /// callbacks (post-launch by definition); the default reads
    /// `NSApplication.shared` lazily and safely. Injectable for the
    /// launch-safety regression test.
    init(
        keyWindowProvider: @escaping () -> Bool = {
            // Only ever called from NSWindow notifications delivered on the
            // main thread (post-launch); assumeIsolated makes that explicit.
            MainActor.assumeIsolated { NSApplication.shared.keyWindow != nil }
        }
    ) {
        hasClosableWindow = false
        let center = NotificationCenter.default
        Publishers.MergeMany(
            center.publisher(for: NSWindow.didBecomeKeyNotification),
            center.publisher(for: NSWindow.didResignKeyNotification),
            center.publisher(for: NSWindow.willCloseNotification),
            center.publisher(for: NSWindow.didMiniaturizeNotification),
            center.publisher(for: NSWindow.didDeminiaturizeNotification)
        )
        .receive(on: DispatchQueue.main) // sample after the transition lands
        .map { _ in keyWindowProvider() }
        .removeDuplicates()
        .sink { [weak self] in self?.hasClosableWindow = $0 }
        .store(in: &subscriptions)
    }
}

/// The app menu's own items (§4.5). Declared on the Settings `Window` scene
/// in `ShiibarCcMenuBarApp` — commands are app-wide regardless of which
/// scene declares them.
struct AppMenuCommands: Commands {
    /// Deliberately a plain `let`, NOT `@ObservedObject` — used for actions
    /// only. Observing `AppState` here is what closed an open submenu on
    /// every agent hook report (see `AppMenuModel` above);
    /// everything the menu RENDERS comes from `menuModel`.
    let state: AppState
    @ObservedObject var menuModel: AppMenuModel
    /// Works from Commands too (measured on-device, M27 harness: a
    /// commands-defined item fired via `performActionForItem` opened the
    /// target `Window` scene).
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            // Same as the ⌄ item: the popover closes (§4.5), the app comes
            // forward (accessory apps need the explicit activate).
            Button("About Shiibar CC") {
                state.willOpenAuxiliaryWindow()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        }
        // §4.5: the app menu holds ONLY the listed items — no Services,
        // no Hide/Hide Others/Show All.
        CommandGroup(replacing: .systemServices) {}
        CommandGroup(replacing: .appVisibility) {}
        CommandGroup(replacing: .appSettings) {
            // Same behavior as the ⌄ items (§4.5): the popover closes, the
            // window stays.
            Button("Settings…") {
                state.willOpenAuxiliaryWindow()
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: SettingsWindow.id)
            }
            .keyboardShortcut(",")
        }
        CommandGroup(after: .appSettings) {
            Divider()
            // §4.5: closes the key window (standard behavior; no File menu
            // to host ⌘W) — or the popover while it is key; disabled when
            // nothing is closable (§8.40 — honest over a silent no-op).
            Button("Close Window") { state.closeKeySurface() }
                .keyboardShortcut("w")
                .disabled(!menuModel.hasClosableWindow)
            Divider()
        }
        CommandGroup(replacing: .appTermination) {
            // §4.5/§8.8: same Quit path as the ⌄ item — waits for the
            // daemon's shutdown ack (with `AppState.quit`'s hard deadline),
            // never a bare `terminate`.
            Button("Quit Shiibar CC") { state.quit() }
                .keyboardShortcut("q")
        }
    }
}

/// Empties the standard File/Format/View/Window/Help command groups.
/// §4.5/§8.41: the EDIT menu stays — its standard Undo/Redo (`.undoRedo`)
/// and Cut/Copy/Paste/Select All (`.pasteboard`) groups are deliberately
/// NOT replaced, because macOS delivers those shortcuts through menu key
/// equivalents: with no Edit menu, ⌘V/⌘A were dead in every text field
/// (the text-field twin of the §8.38(5) WebView ⌘C hole). The items stay
/// standard responder-chain targets — no custom handlers. `MainMenuPruner`
/// hides the other husk menus. Split in two because `CommandsBuilder` caps
/// a block at 10 children.
struct RemoveStandardMenusCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .textEditing) {}
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .sidebar) {}
        CommandGroup(replacing: .windowList) {}
    }

    struct Extra: Commands {
        var body: some Commands {
            CommandGroup(replacing: .windowSize) {}
            CommandGroup(replacing: .windowArrangement) {}
            CommandGroup(replacing: .textFormatting) {}
            CommandGroup(replacing: .help) {}
        }
    }
}

/// Keeps `NSApp.mainMenu` down to the app menu alone (§4.5 "one app menu
/// only", M27 T2) — see the file header for why `.commands` cannot do this
/// by itself. Started once from `AppDelegate.applicationDidFinishLaunching`
/// and left running: pruning is cheap, coalesced, and harmless while the
/// menu bar isn't ours (accessory state).
@MainActor
final class MainMenuPruner {
    private var observers: [NSObjectProtocol] = []
    private var repruneScheduled = false
    private var repruneDeferredUntilTrackingEnds = false
    /// Open menu-tracking sessions (menu bar or any popped-up menu).
    private var trackingDepth = 0

    func start() {
        prune()
        let center = NotificationCenter.default
        // Re-prune when items land in the main menu. HIDING (see `prune`)
        // makes this a launch-time-only event in practice: measured
        // on-device (M27 bug harness), a commands invalidation while the
        // husk items are merely hidden re-adds NOTHING — SwiftUI
        // reconfigures its existing items in place and leaves `isHidden`
        // alone. Removed items, by contrast, were re-added SYNCHRONOUSLY
        // mid-invalidation — even while a menu-tracking session was open —
        // which is what closed an open menu the moment a submenu
        // (or any AppState churn, e.g. an agent hook report) invalidated
        // the commands. This observer stays as the backstop for a macOS
        // that rebuilds differently.
        observers.append(center.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let menu = notification.object as? NSMenu else { return }
            Task { @MainActor in
                self.scheduleRepruneIfNeeded(addedTo: menu)
            }
        })
        // Belt-and-braces for that backstop: never mutate the main menu
        // while ANY menu-tracking session is active — mutating the menu a
        // user is browsing is exactly the bug class this type caused once.
        // A prune requested mid-tracking runs when tracking ends.
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.trackingDepth += 1
            }
        })
        observers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.trackingDepth = max(0, self.trackingDepth - 1)
                if self.trackingDepth == 0, self.repruneDeferredUntilTrackingEnds {
                    self.repruneDeferredUntilTrackingEnds = false
                    self.prune()
                }
            }
        })
    }

    /// Next-turn + coalesced: SwiftUI adds several items in a burst, and
    /// mutating the menu mid-burst from its own notification would fight
    /// the enumeration that's inserting them. Deferred entirely while a
    /// tracking session is open (see `start`).
    private func scheduleRepruneIfNeeded(addedTo menu: NSMenu) {
        guard menu === NSApp.mainMenu else { return }
        if trackingDepth > 0 {
            repruneDeferredUntilTrackingEnds = true
            return
        }
        guard !repruneScheduled else { return }
        repruneScheduled = true
        DispatchQueue.main.async {
            self.repruneScheduled = false
            self.prune()
        }
    }

    deinit {
        let observers = self.observers
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// HIDE, never remove (M27 menu-closing bugfix, measured on-device):
    /// removing the husk menus made every SwiftUI commands invalidation
    /// re-add them synchronously — a structural main-menu mutation that
    /// could land mid-tracking and close whatever menu the user had open
    /// (deterministically so on hovering a submenu item, whose opening
    /// triggers an invalidation). Hidden items don't render in the menu
    /// bar, but they keep SwiftUI's menu structure intact, so an
    /// invalidation reconfigures items in place: zero `didAddItem` churn,
    /// `isHidden` untouched, open menus unaffected.
    private func prune() {
        guard let mainMenu = NSApp.mainMenu, let appMenuItem = mainMenu.items.first else { return }
        // §4.5/§8.41: the app menu AND Edit survive; everything else hides.
        // The title match is safe because this app ships unlocalized
        // (English-only UI strings — repo rule), so the standard menu is
        // always titled "Edit".
        for item in mainMenu.items.dropFirst() where !item.isHidden && item.title != "Edit" {
            item.isHidden = true
        }
        // §4.5/§8.42: dictation and the character palette are suppressed by
        // their UserDefaults keys (AppDelegate — behavior-verified). The
        // Edit SUBMENU's remaining contents are deliberately left alone:
        // SwiftUI's own menu delegate rebuilds them when the menu opens,
        // reverting any hide OR removal (probe-measured — a pre-open clean
        // held until didBeginTracking and was undone mid-open), so Delete,
        // AutoFill, and the surplus separators cannot be pruned by any
        // sanctioned mechanism from here.
        // Replaced-empty command groups leave their group separators behind
        // — hide the extras (leading runs and trailing) so the app menu
        // shows single separators exactly where §4.5 puts them.
        guard let appMenu = appMenuItem.submenu else { return }
        var lastVisibleWasSeparator = true // leading separators: hide
        for item in appMenu.items where !item.isHidden {
            if item.isSeparatorItem {
                if lastVisibleWasSeparator {
                    item.isHidden = true
                } else {
                    lastVisibleWasSeparator = true
                }
            } else {
                lastVisibleWasSeparator = false
            }
        }
        for item in appMenu.items.reversed() {
            if item.isSeparatorItem {
                if !item.isHidden { item.isHidden = true }
            } else if !item.isHidden {
                break // trailing separators (if any) are now hidden
            }
        }
    }
}
