// Conversations window container (DESIGN.md §4.6, M35 T3): the hidden-title-
// bar `Window` scene's content, plus the window-lifecycle view model that
// (a) reports open/close to `AppState`'s shared regular-app policy owner
// (§8.30, extended to "Agents OR Conversations" — M35 T3), (b) drives the
// content view model's open/close flow (index-on-open, scroll-memory reset),
// and (c) gives the window a frame autosave name so its size AND position
// persist across launches (§9 — unlike the Agents window, which re-opens
// under the icon and remembers height only).
//
// Content is fully in `ConversationsContentView`; this file is the window
// seam, mirroring `AgentsWindowView`'s split of view model vs shared list.

import AppKit
import Combine
import ShiibarCcCore
import SwiftUI

/// Owns the Conversations window's visibility and lifecycle wiring. Window
/// lifecycle is tracked with `didBecomeKey` (+ "not already visible") /
/// `willClose`, filtered by the window's stable title — the same technique
/// as `AgentsWindowViewModel` / `SetupCheckViewModel`.
@MainActor
final class ConversationsWindowViewModel: ObservableObject {
    @Published private(set) var isVisible = false

    private weak var appState: AppState?
    let content: ConversationsViewModel
    private var observers: [NSObjectProtocol] = []
    private var didSetAutosaveName = false

    /// UserDefaults autosave name for the window frame (§9: remember size and
    /// position). AppKit persists the frame under this key on every
    /// move/resize once set, and restores it on a fresh launch.
    private static let frameAutosaveName = "cc.shiibar.conversationsWindow"

    init(appState: AppState) {
        self.appState = appState
        self.content = ConversationsViewModel(appState: appState)
        observeWindowLifecycle()
    }

    deinit {
        let observers = self.observers
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeWindowLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title == ConversationsWindow.title, let self else { return }
            Task { @MainActor in self.noteWindowBecameKey(window) }
        })
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title == ConversationsWindow.title, let self else { return }
            Task { @MainActor in self.noteWindowClosed() }
        })
    }

    private func noteWindowBecameKey(_ window: NSWindow) {
        // Attach the frame autosave name once, restoring any saved frame
        // (§9): AppKit then saves on every later move/resize automatically.
        if !didSetAutosaveName {
            didSetAutosaveName = true
            window.setFrameUsingName(Self.frameAutosaveName)
            window.setFrameAutosaveName(Self.frameAutosaveName)
        }
        guard !isVisible else { return }
        isVisible = true
        appState?.noteRegularWindowOpened(title: ConversationsWindow.title)
        // §4.6/T7: index-on-open flow (progress in the status line, then a
        // search for the current query).
        content.windowOpened()
    }

    private func noteWindowClosed() {
        isVisible = false
        appState?.noteRegularWindowClosed(title: ConversationsWindow.title)
        content.windowClosed()
    }
}

struct ConversationsWindowView: View {
    @ObservedObject var state: AppState
    @StateObject private var windowState: ConversationsWindowViewModel

    init(state: AppState) {
        self.state = state
        _windowState = StateObject(wrappedValue: ConversationsWindowViewModel(appState: state))
    }

    var body: some View {
        ConversationsContentView(viewModel: windowState.content)
            // Minimum content size; the window is resizable both axes from
            // here up (§9). The traffic-light band is added on top by AppKit
            // (`.hiddenTitleBar`), same as the Agents window.
            .frame(
                minWidth: 480,
                idealWidth: ConversationsWindow.defaultWidth,
                maxWidth: .infinity,
                minHeight: 320,
                idealHeight: ConversationsWindow.defaultHeight,
                maxHeight: .infinity
            )
            .onAppear {
                // LSUIElement (accessory) apps need an explicit activate to
                // bring a newly opened window forward — same requirement as
                // Settings / Setup Check / Agents. Belt-and-braces: the ⌄ /
                // app-menu open sites also call `NSApp.activate`.
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
