// App menu (DESIGN.md §4.5 "one app menu only" / §8.30, M27 T2): while the
// Agents window exists the app is a regular app (AgentsWindowViewModel,
// M27 T1) and shows EXACTLY one menu — the app menu — at the top of the
// screen: About Shiibar CC / - / Settings… (⌘,) / Setup Check… / - /
// Rescan (⌘R) / Clear badges (disabled when nothing is unreviewed) /
// Sort by (submenu) / - / Keep on Top (checkmark toggle) / Close Window
// (⌘W) / Quit Shiibar CC (⌘Q).
// Every item behaves exactly like its ⌄-menu namesake.
//
// Two mechanisms cooperate (both measured on-device, macOS 14 harness, M27):
//  - `.commands` (below) REPLACES the standard command groups, which
//    empties the File/Edit/Format/View/Window/Help menus but cannot remove
//    the menus themselves — SwiftUI leaves empty husks plus system-injected
//    Edit items (AutoFill / Start Dictation / Emoji & Symbols), and stacked
//    separators where replaced-empty app-menu groups used to be.
//  - `MainMenuPruner` (bottom) therefore HIDES everything but the app menu
//    (and the surplus separators). Hiding, not removing, is load-bearing:
//    removed items were re-added synchronously by every commands
//    invalidation — including one landing while the user had the menu open,
//    which closed it (the M27 Sort-by-hover bug) — while hidden items keep
//    SwiftUI's structure intact so invalidations reconfigure in place with
//    zero churn. See `prune()` for the measurements.

import AppKit
import Combine
import ShiibarCcCore
import SwiftUI

/// The menu-facing slice of `AppState`, re-published ONLY when a value the
/// menu actually renders genuinely changes (M29 bugfix, measured
/// on-device): with the Commands observing `AppState` directly, EVERY
/// `@Published` change — notably the `agents` array churning on each hook
/// report — invalidated the commands content, and a commands invalidation
/// landing while the Sort by submenu was open closed that submenu on the
/// spot (the top-level menu survives thanks to `MainMenuPruner`'s
/// hide-not-remove approach, but the Picker's submenu does not; harness:
/// the first churn killed an open submenu within ~0.2s, while this deduped
/// facade held one open through five churn bursts). The menu renders
/// exactly two values — Clear badges' enabled state and the Sort by
/// selection — so only genuine changes to those may invalidate it (a menu
/// refresh on a real Clear-badges flip is acceptable).
@MainActor
final class AppMenuModel: ObservableObject {
    @Published private(set) var hasUnreviewed: Bool
    @Published private(set) var sortMode: SortMode
    /// Keep on Top checkmark state (§4.5/§8.33, M30) — routed through this
    /// facade like the other two, so agent churn can never invalidate the
    /// menu through it.
    @Published private(set) var keepOnTop: Bool
    /// Whether the Conversations window exists (§4.6, M35 T8) — gates the app
    /// menu's "Conversations…" item. Routed through this facade like the
    /// others; window open/close is infrequent, so an invalidation on a real
    /// change is fine, and agent churn (which never touches it) can't reach
    /// the menu through it.
    @Published private(set) var conversationsWindowOpen: Bool
    /// Whether the Agents (list) window exists (§4.5, M35 T3) — gates "Keep
    /// on Top", which is Agents-window-only and meaningless when that window
    /// is absent. Reachable now that the Conversations window can also raise
    /// the app menu with no Agents window present.
    @Published private(set) var agentsWindowOpen: Bool

    private var subscriptions: Set<AnyCancellable> = []

    init(state: AppState) {
        hasUnreviewed = state.hasUnreviewed
        sortMode = state.sortMode
        keepOnTop = state.keepAgentsWindowOnTop
        conversationsWindowOpen = state.isConversationsWindowOpen
        agentsWindowOpen = state.isAgentsWindowOpen
        // `$agents` emits the NEW array (willSet timing), so deriving from
        // the emitted value — not from `state.hasUnreviewed`, which still
        // reads the old array at that instant — is load-bearing.
        state.$agents
            .map { agents in agents.contains { $0.unreviewed } }
            .removeDuplicates()
            .sink { [weak self] in self?.hasUnreviewed = $0 }
            .store(in: &subscriptions)
        state.$sortMode
            .removeDuplicates()
            .sink { [weak self] in self?.sortMode = $0 }
            .store(in: &subscriptions)
        state.$keepAgentsWindowOnTop
            .removeDuplicates()
            .sink { [weak self] in self?.keepOnTop = $0 }
            .store(in: &subscriptions)
        state.$openRegularWindowTitles
            .map { $0.contains(ConversationsWindow.title) }
            .removeDuplicates()
            .sink { [weak self] in self?.conversationsWindowOpen = $0 }
            .store(in: &subscriptions)
        state.$openRegularWindowTitles
            .map { $0.contains(AgentsWindow.title) }
            .removeDuplicates()
            .sink { [weak self] in self?.agentsWindowOpen = $0 }
            .store(in: &subscriptions)
    }
}

/// The app menu's own items (§4.5, M27 T2). Lives on the Agents `Window`
/// scene in `ShiibarCcMenuBarApp` — commands are app-wide regardless of
/// which scene declares them.
struct AppMenuCommands: Commands {
    /// Deliberately a plain `let`, NOT `@ObservedObject` — used for actions
    /// only. Observing `AppState` here is what closed an open Sort by
    /// submenu on every agent hook report (see `AppMenuModel` above);
    /// everything the menu RENDERS comes from `menuModel`.
    let state: AppState
    @ObservedObject var menuModel: AppMenuModel
    /// Works from Commands too (measured on-device, M27 harness: a
    /// commands-defined item fired via `performActionForItem` opened the
    /// target `Window` scene).
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            // Same standard About panel as the ⌄ item. No `NSApp.activate`
            // needed here: the app menu is only reachable while the app is
            // regular AND frontmost (the accessory-state caveat is the ⌄
            // path's, §4.5).
            Button("About Shiibar CC") { NSApp.orderFrontStandardAboutPanel(nil) }
        }
        // §4.5: the app menu holds ONLY the listed items — no Services,
        // no Hide/Hide Others/Show All.
        CommandGroup(replacing: .systemServices) {}
        CommandGroup(replacing: .appVisibility) {}
        CommandGroup(replacing: .appSettings) {
            // Same handlers as the ⌄ items (§4.5: identical behavior), sans
            // the dropdown-dismissal half — no dropdown is open when the
            // click comes from the app menu, and the Agents window must not
            // close on hand-off anyway (§4.5, M27 T2).
            Button("Settings…") { openWindow(id: SettingsWindow.id) }
                .keyboardShortcut(",")
            Button("Setup Check…") { openWindow(id: SetupCheckWindow.id) }
        }
        CommandGroup(after: .appSettings) {
            Divider()
            Button("Rescan") { state.runReconcile(showFeedback: true) }
                .keyboardShortcut("r")
            Button("Clear badges") { state.clearBadges() }
                .disabled(!menuModel.hasUnreviewed) // §4.5/§8.24, same as ⌄
            Picker("Sort by", selection: Binding(
                get: { menuModel.sortMode },
                set: { state.setSortMode($0) }
            )) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Text(mode.menuTitle).tag(mode)
                }
            }
        }
        CommandGroup(replacing: .appTermination) {
            // Keep on Top (§4.5/§8.33, M30): first item of the last group,
            // above Close Window; a `Toggle` renders as a checkmarked menu
            // item showing the current value. No shortcut (§4.5). ON keeps
            // the Agents window at the floating level — level only, no
            // Space following (§8.33); default OFF, remembered across
            // opens and launches (`AppState.setKeepAgentsWindowOnTop`).
            Toggle("Keep on Top", isOn: Binding(
                get: { menuModel.keepOnTop },
                set: { state.setKeepAgentsWindowOnTop($0) }
            ))
            // §4.5/M35 T3: Agents-window-only — disabled when the list window
            // is absent (the app menu can now also be raised by the
            // Conversations window, which has no window level to pin).
            .disabled(!menuModel.agentsWindowOpen)
            // §4.5: standard close-the-key-window behavior. Lives in the
            // app menu because there is no File menu to host ⌘W.
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            // Conversations… (§4.5/§4.6, M35 T8): below Close Window, above
            // Quit — identical to the ⌄ menu's item. Disabled while the
            // Conversations window exists (via the deduped facade).
            Button("Conversations…") { openWindow(id: ConversationsWindow.id) }
                .disabled(menuModel.conversationsWindowOpen)
            // §4.5/§8.8: same Quit path as the ⌄ item — waits for the
            // daemon's shutdown ack (with `AppState.quit`'s hard deadline),
            // never a bare `terminate`.
            Button("Quit Shiibar CC") { state.quit() }
                .keyboardShortcut("q")
        }
    }
}

/// Empties the standard File/Edit/Format/View/Window/Help command groups
/// (§4.5: no menus besides the app menu). `MainMenuPruner` removes the
/// husk menus this leaves behind. Split in two because `CommandsBuilder`
/// caps a block at 10 children.
struct RemoveStandardMenusCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .undoRedo) {}
        CommandGroup(replacing: .pasteboard) {}
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
        // which is what closed an open menu the moment Sort by's submenu
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
    /// (deterministically so on hovering Sort by, whose submenu opening
    /// triggers an invalidation). Hidden items don't render in the menu
    /// bar, but they keep SwiftUI's menu structure intact, so an
    /// invalidation reconfigures items in place: zero `didAddItem` churn,
    /// `isHidden` untouched, open menus unaffected.
    private func prune() {
        guard let mainMenu = NSApp.mainMenu, let appMenuItem = mainMenu.items.first else { return }
        for item in mainMenu.items.dropFirst() where !item.isHidden {
            item.isHidden = true
        }
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
