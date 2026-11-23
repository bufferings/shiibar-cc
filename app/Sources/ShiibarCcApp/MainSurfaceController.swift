// The AppKit side of the two surfaces (DESIGN.md §4.5 "surface form" /
// "tray icon click" / "popover" / "window" / "key operations" / "⌄ menu" /
// "global hotkey", §8.49 / §8.50 / §8.61): the status item (drawn by `TrayIconRenderer`), the
// `NSPopover` with its bottom-edge height drag, the single window, the key
// monitor that runs before the focused view, the ⌄ menu, and the global
// hotkey's presses (the tray click's branch). The shared layout and state live in
// `MainSurfaceView` / `MainSurfaceModel`; this type only shows, hides and
// routes.

import AppKit
import Combine
import ShiibarCcCore
import SwiftUI
import WebKit

@MainActor
final class MainSurfaceController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let state: AppState
    private var model: MainSurfaceModel { state.surface }
    private let defaults: UserDefaults

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var popoverContainer: NSView?
    private var window: NSWindow?
    private var keyMonitor: Any?
    /// Sees every left mouse-down before AppKit dispatches it (§4.5 "row
    /// click": the snapshot of the surface's key status and focus).
    private var mouseDownMonitor: Any?
    /// The popover's window key-status observers (installed per show; the
    /// main window reports through its delegate).
    private var popoverKeyObservers: [NSObjectProtocol] = []
    /// When each surface's window last became key (system uptime) —
    /// `SurfaceKeyAtPress`.
    private var becameKeyAt: [MainSurface: TimeInterval] = [:]
    /// First-responder observations of the popover's window and the main
    /// window: where the keyboard focus is decides the keys (§4.5 "key
    /// operations"), the key hints and the bottom panel's buttons.
    private var popoverFocusObservation: NSKeyValueObservation?
    private var windowFocusObservation: NSKeyValueObservation?
    /// The main window's `contentLayoutRect`: the title bar height over the
    /// full-screen content follows it (`WindowFullScreenInset`).
    private var contentLayoutObservation: NSKeyValueObservation?
    /// The window has finished entering full screen and has not started
    /// leaving it: only then does a title bar over the content count as
    /// the top inset (during a transition the frame and the title bar are
    /// still changing).
    private var fullScreenSettled = false
    /// When the popover last closed: the status-item click that caused a
    /// transient close arrives right after it and must not reopen it.
    private var lastPopoverClose: Date = .distantPast
    private var heightDrag: PopoverHeightDrag?
    /// Set while a just-opened window's first key event is pending.
    private var skipNextWindowKey = false
    /// The list focus owed to a window the hotkey or a notification click
    /// opened from closed (§4.5 "global hotkey", "notification click";
    /// `PendingListFocus`).
    private var pendingListFocus = PendingListFocus()
    /// Set while `Open in popover` closes the window: the app stays regular
    /// until the popover it opens closes (`RegularAppHold`).
    private var closingWindowForPopover = false
    private var subscriptions: Set<AnyCancellable> = []
    /// Redraws the tray when the menu bar's appearance flips (the dot
    /// variant is not a template image and picks its glyph color by hand).
    private var appearanceObservation: NSKeyValueObservation?
    /// Sets the tray image only when what it depicts changed.
    private var trayImageUpdater: TrayImageUpdater?
    /// Opens the Settings `Window` scene (captured from a SwiftUI view on
    /// whichever surface appeared first — see `surfaceRootView`).
    var openSceneWindow: ((String) -> Void)?
    private lazy var menuHandler = HeaderMenuHandler(controller: self)
    /// Applies the pin's level to Settings as it becomes key.
    private var auxiliaryKeyObserver: NSObjectProtocol?
    /// The About panel, once shown: the panel the About call brought on
    /// screen (AppKit gives it no public handle).
    private weak var aboutPanel: NSWindow?
    /// Closes the popover when the app stops being active (§4.5 "popover",
    /// §8.58).
    private var deactivationCloser: PopoverDeactivationCloser?

    /// The window's `title` (§4.5: not drawn; Mission Control and the
    /// title filters use it).
    static let windowTitle = "Shiibar CC"

    init(state: AppState, defaults: UserDefaults = .standard) {
        self.state = state
        self.defaults = defaults
        super.init()
    }

    func start() {
        setUpStatusItem()
        setUpPopover()
        deactivationCloser = PopoverDeactivationCloser(
            center: .default,
            isPopoverShown: { [weak self] in self?.popover.isShown ?? false },
            closePopover: { [weak self] in self?.closePopover() }
        )
        setUpKeyMonitor()
        setUpMouseDownMonitor()
        model.onClosePopover = { [weak self] in self?.closePopover() }
        model.onOpenInWindow = { [weak self] in self?.openWindow() }
        model.onCloseWindowForPopover = { [weak self] in self?.closeWindowForPopover() }
        model.onShowPopoverFromWindow = { [weak self] in self?.showPopoverFromWindow() }
        model.onPresentMenu = { [weak self] anchor, surface in self?.presentMenu(anchor: anchor, surface: surface) }
        model.onPresentRowMenu = { [weak self] items, anchor, _, completion in
            guard let self else { return completion(nil) }
            self.presentRowMenu(items: items, anchor: anchor, completion: completion)
        }
        model.onKeepOnTopChanged = { [weak self] _ in
            self?.applyWindowLevel()
            self?.applyAuxiliaryWindowLevels()
        }
        state.showAboutPanel = { [weak self] in self?.showAboutPanel() }
        // Settings opens from the ⌄ menus, the app menu and ⌘, and SwiftUI
        // can create it after `openWindow` returns: it takes the pin's level
        // whenever it becomes key.
        auxiliaryKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow else { return }
                self.applyAuxiliaryLevel(to: window)
            }
        }
        model.onFocusList = { [weak self] surface in self?.focusList(on: surface) }
        model.onMakeSurfaceKey = { [weak self] surface in self?.makeKey(surface) }
        state.closeKeySurface = { [weak self] in self?.closeKeySurface() }
        state.willOpenAuxiliaryWindow = { [weak self] in self?.closePopover() }
        // Dock click / reopen: a raise, which owes the list no focus.
        state.raiseMainWindow = { [weak self] in self?.raiseWindow() }
        state.showRowForNotification = { [weak self] target in self?.showRowForNotification(target: target) }
        state.hotKey.onPressed = { [weak self] in self?.hotKeyPressed() }
        // Redraw the tray on every state change (§4.5): agents and
        // connection.
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTrayImage() }
            .store(in: &subscriptions)
        refreshTrayImage()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // §4.5: the icon receives clicks itself (no OS-opened menu).
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Shiibar CC")
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.refreshTrayImage() }
            }
        }
        statusItem = item
        trayImageUpdater = TrayImageUpdater(
            state: { [weak self] in self?.state.trayIcon ?? Rollup.icon(statuses: [], hasUnreviewed: false, daemonConnected: false) },
            appearance: { [weak item] in item?.button?.effectiveAppearance },
            setImage: { [weak item] image in item?.button?.image = image })
    }

    private func refreshTrayImage() {
        trayImageUpdater?.refresh()
    }

    /// The window is open: on screen or minimized to the Dock (closing
    /// orders it out; minimizing keeps it open).
    private var isWindowOpen: Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    /// §4.5 "tray icon click": the window is frontmost when the app is
    /// active, the window is key, not minimized, and on the current Space —
    /// read from these four conditions only, at the moment the status
    /// item's action or the hotkey handler runs.
    private var isWindowFrontmost: Bool {
        guard let window else { return false }
        return WindowFrontmost.isFrontmost(
            appActive: NSApp.isActive,
            windowKey: window.isKeyWindow,
            windowMiniaturized: window.isMiniaturized,
            windowOnActiveSpace: window.isOnActiveSpace)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        toggleSurface(from: .trayClick)
    }

    /// The global hotkey was pressed (§4.5 "global hotkey"): the tray
    /// click's branch, with the list focused afterwards.
    func hotKeyPressed() {
        toggleSurface(from: .hotKey)
    }

    /// §4.5 "tray icon click" / "global hotkey" (`SurfaceToggleAction`).
    private func toggleSurface(from source: SurfaceToggleSource) {
        let action = SurfaceToggleAction.decide(
            form: model.surfaceForm,
            popoverShown: popover.isShown,
            windowOpen: isWindowOpen,
            windowFrontmost: isWindowFrontmost)
        let focus = SurfaceToggleFocus.after(action, source: source)
        switch action {
        case .closePopover:
            popover.performClose(nil)
        case .openPopover:
            // The click that just closed the transient popover (outside
            // click on the icon) must not reopen it.
            if source == .trayClick, Date().timeIntervalSince(lastPopoverClose) < 0.3 { return }
            showPopover(focus: focus ?? .initial)
        case .openWindow:
            openWindow(focus: focus ?? .initial)
        case .raiseWindow:
            raiseWindow()
            if focus == .list { focusAfterHotKey() }
        case .closeWindow:
            // The red button's path (§4.5 "window"): `windowWillClose` hides
            // the surface and returns to the accessory app; nothing here
            // activates this app or another one.
            window?.performClose(nil)
        }
    }

    /// A notification click on a session the app cannot jump to (§4.5
    /// "notification click"): open the surface of the current form (a
    /// window that is open comes forward), then the list selects the row,
    /// starts the mark-read timer over and takes focus. The surface opens
    /// without its own focus request, so nothing replaces the list's focus.
    /// The same timing as the hotkey's focus: a window opened from closed
    /// waits until it has become key (`PendingListFocus`); otherwise it is
    /// deferred a turn, so the shown surface's responder chain settles
    /// first.
    private func showRowForNotification(target: String) {
        switch model.surfaceForm {
        case .popover:
            if !popover.isShown { showPopover(focus: nil) }
        case .window:
            if !isWindowOpen {
                openWindow(focus: nil, notificationTarget: target)
                return
            }
            raiseWindow()
        }
        selectRowForNotification(target: target)
    }

    /// The list part of a notification click (`showRowForNotification`),
    /// deferred a turn.
    private func selectRowForNotification(target: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model.notificationClicked(target: target) }
        }
    }

    /// Runs what `pendingListFocus` handed back.
    private func runPendingListFocus(_ purpose: PendingListFocus.Purpose?) {
        switch purpose {
        case .hotKey:
            focusAfterHotKey()
        case .notification(let target):
            selectRowForNotification(target: target)
        case nil:
            break
        }
    }

    /// The list takes focus (§4.5 "global hotkey"). Deferred a turn, like
    /// the search field's focus request on open: the shown surface's
    /// responder chain settles first.
    private func focusAfterHotKey() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model.openedByHotKey() }
        }
    }

    // MARK: - Popover

    private func storedPopoverHeight() -> Double? {
        defaults.object(forKey: MainSurfaceDefaultsKeys.popoverHeight) as? Double
    }

    /// §9: the tallest height that fits the visible area of the status
    /// item's display. Assumption: the popover arrow and the gap under the
    /// menu bar take 24pt.
    private func maximumPopoverHeight() -> Double {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        return Double((screen?.visibleFrame.height ?? 800) - 24)
    }

    private func setUpPopover() {
        let initialHeight = PopoverHeight.heightToOpen(stored: storedPopoverHeight(), maximum: maximumPopoverHeight())
        let size = NSSize(width: popoverWidth(model.textSize.size), height: initialHeight)
        let hosting = NSHostingView(rootView: Self.surfaceRootView(model: model, surface: .popover) { [weak self] open in
            self?.openSceneWindow = open
        })
        hosting.sizingOptions = []
        // Same layout contract as the window: no safe area reaches the views.
        hosting.safeAreaRegions = []
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        // §4.5 / §9: the bottom-edge drag area sits above the content, so it
        // receives the mouse before anything under it.
        let strip = PopoverResizeStrip(frame: NSRect(x: 0, y: 0, width: size.width, height: PopoverHeight.dragHandleHeight))
        strip.autoresizingMask = [.width, .maxYMargin]
        strip.onBegin = { [weak self] in
            guard let self else { return }
            self.heightDrag = PopoverHeightDrag(startHeight: Double(self.popover.contentSize.height))
        }
        strip.onDrag = { [weak self] delta in self?.updateHeightDrag(delta: delta) }
        strip.onEnd = { [weak self] in self?.endHeightDrag() }
        container.addSubview(strip)
        popoverContainer = container
        let controller = NSViewController()
        controller.view = container
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        // The size must follow the drag without an animation.
        popover.animates = false
        popover.delegate = self
        // §4.5 "text size": the width follows a change made while the
        // popover is shown (keys or Settings); the height stays.
        model.textSize.$size
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] size in
                guard let self, self.popover.isShown else { return }
                self.popover.contentSize = NSSize(width: self.popoverWidth(size), height: self.popover.contentSize.height)
            }
            .store(in: &subscriptions)
    }

    /// §4.5 / §9: the popover width for a text size (420pt at 13).
    private func popoverWidth(_ size: TextSize) -> CGFloat {
        CGFloat(size.popoverWidth)
    }

    private func updateHeightDrag(delta: Double) {
        guard var drag = heightDrag else { return }
        let entered = drag.update(dragDelta: delta, maximum: maximumPopoverHeight())
        heightDrag = drag
        if entered {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        popover.contentSize = NSSize(width: popover.contentSize.width, height: drag.height)
    }

    /// §4.5: the height is remembered when the drag ends — only when the
    /// drag changed it (a plain click keeps the stored value; §9).
    private func endHeightDrag() {
        guard let drag = heightDrag else { return }
        heightDrag = nil
        if let height = drag.heightToPersist {
            defaults.set(height, forKey: MainSurfaceDefaultsKeys.popoverHeight)
        }
    }

    /// `focus` nil: no focus request (the caller moves the focus itself).
    func showPopover(focus: SurfaceToggleFocus?) {
        guard let button = statusItem?.button else { return }
        // A remembered height above the maximum opens at the maximum; the
        // stored value itself stays (§9).
        let height = PopoverHeight.heightToOpen(stored: storedPopoverHeight(), maximum: maximumPopoverHeight())
        popover.contentSize = NSSize(width: popoverWidth(model.textSize.size), height: height)
        model.surfaceDidShow(.popover)
        NSApp.activate(ignoringOtherApps: true)
        // The popover follows the app's appearance (Settings > Appearance;
        // System = the OS setting); a popover with no appearance set does
        // not (NSPopover.h; §4.5 "popover").
        // Set on every show so a change made while it was closed applies.
        popover.appearance = NSApp.effectiveAppearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installPopoverBackground()
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverFocusObservation = observeFocus(of: popoverWindow, surface: .popover)
            observeKeyStatus(ofPopoverWindow: popoverWindow)
        }
        switch focus {
        case .list:
            focusAfterHotKey()
        case .initial:
            model.requestInitialFocus()
        case nil:
            break
        }
    }

    /// Paints the popover's frame (the arrow included) with the list's
    /// opaque ground, so what is behind the popover does not show through
    /// its material (window-design.html `--cardsbg`).
    private func installPopoverBackground() {
        guard let frameView = popover.contentViewController?.view.window?.contentView?.superview,
              !frameView.subviews.contains(where: { $0 is PopoverBackgroundView }) else { return }
        let background = PopoverBackgroundView(frame: frameView.bounds)
        background.autoresizingMask = [.width, .height]
        frameView.addSubview(background, positioned: .below, relativeTo: frameView.subviews.first)
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        statusItem?.button?.highlight(false)
        removePopoverKeyObservers()
        model.surfaceDidHide(.popover)
        // The popover `Open in popover` opened returns the app to
        // accessory now (§4.5).
        state.notePopoverClosed()
    }

    private var popoverWindow: NSWindow? {
        popover.isShown ? popover.contentViewController?.view.window : nil
    }

    // MARK: - Window

    /// Opens the window (`Open in window`, and the tray click or the hotkey
    /// in the window form — one path: the regular-app switch, the
    /// remembered frame, the History refetch). `focus` is where the focus
    /// goes once it is open (§4.5 "window" / "global hotkey"); nil = no
    /// focus request (the caller moves the focus itself).
    /// `notificationTarget`: a notification click opened it; the row is
    /// selected once the window has become key (`PendingListFocus`).
    func openWindow(focus: SurfaceToggleFocus? = .initial, notificationTarget: String? = nil) {
        let opening = !isWindowOpen
        // Before the popover closes: when the popover `Open in popover`
        // opened is shown, the app stays regular for the window instead of
        // returning to accessory as the popover closes.
        if opening {
            state.noteRegularWindowOpened()
        }
        closePopover()
        let window = self.window ?? makeWindow()
        self.window = window
        applyWindowLevel()
        if opening {
            // The model forgot the full-screen state when the window closed;
            // read it from the window again (and the toolbar with it).
            syncFullScreenState(of: window)
            raiseFrameToMinimum(window)
            // The open itself is the trigger (§4.6); the key event that
            // follows must not run index -> search a second time.
            skipNextWindowKey = true
            model.surfaceDidShow(.window)
        }
        let pendingPurpose: PendingListFocus.Purpose?
        if let notificationTarget {
            pendingPurpose = .notification(target: notificationTarget)
        } else {
            pendingPurpose = focus == .list ? .hotKey : nil
        }
        if let pendingPurpose {
            let id = pendingListFocus.opened(for: pendingPurpose, at: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.asyncAfter(deadline: .now() + PendingListFocus.validSeconds) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.runPendingListFocus(self.pendingListFocus.timeoutDue(id: id))
                }
            }
        } else {
            pendingListFocus.clear()
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        reportFocus(of: window, surface: .window)
        // Activation can complete later; `windowDidBecomeKey` reports then.
        model.surfaceKeyChanged(surface: .window, isKey: window.isKeyWindow)
        if focus == .initial {
            model.requestInitialFocus()
        }
        // Open Settings / About now float over the pinned
        // window.
        applyAuxiliaryWindowLevels()
    }

    /// `Open in popover`, first step (§4.5 "header row"): close the window
    /// without returning to accessory — that waits for the popover the
    /// operation opens next to close (`RegularAppHold`).
    private func closeWindowForPopover() {
        guard let window, isWindowOpen else { return }
        closingWindowForPopover = true
        window.close()
        closingWindowForPopover = false
    }

    /// `Open in popover`, last step: show the popover. When it could not be
    /// shown (no status item button), release the app's regular hold as a
    /// popover close would, so the app does not stay regular with neither
    /// surface shown.
    private func showPopoverFromWindow() {
        showPopover(focus: .initial)
        if !popover.isShown {
            state.notePopoverClosed()
        }
    }

    func raiseWindow() {
        guard let window, isWindowOpen else { return }
        pendingListFocus.clear()
        Self.raise(window)
    }

    /// Bring a window back: deminiaturize + activate + front (§8.43 — the
    /// same semantics as the Dock-click reopen path). Never moves it.
    static func raise(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: MainWindowMetrics.initialWidth, height: MainWindowMetrics.initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar gives the title bar the height the header
        // row's traffic lights are centered on (`SurfaceMetrics`).
        window.toolbar = NSToolbar(identifier: "cc.shiibar.mainWindow.toolbar")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        // §4.5: a window on another Space moves to the current one when
        // raised (no Space switch); it never joins all Spaces.
        window.collectionBehavior = [.moveToActiveSpace]
        // Kept for AppKit's own resize limits; the hosting content view
        // resets it to zero once the window is shown, so
        // `windowWillResize(_:to:)` enforces the minimum.
        window.contentMinSize = Self.minimumContentSize
        window.delegate = self
        let hosting = FirstMouseHostingView(rootView: Self.surfaceRootView(model: model, surface: .window) { [weak self] open in
            self?.openSceneWindow = open
        })
        hosting.sizingOptions = []
        // The layout places the header row under the hidden title bar itself
        // (`SurfaceMetrics.windowTrafficLightCenter`). Without this, the
        // title-bar safe area reaches the list's `ScrollView`, which then
        // extends its scroll view up to the window top (over the header row)
        // and scrolls the rows over the header.
        hosting.safeAreaRegions = []
        window.contentView = hosting
        // §4.5 / §9: remember the frame; first open centered at the §9 size.
        if !window.setFrameUsingName(MainSurfaceDefaultsKeys.mainWindowFrameAutosaveName) {
            window.setContentSize(NSSize(width: MainWindowMetrics.initialWidth, height: MainWindowMetrics.initialHeight))
            window.center()
        }
        window.setFrameAutosaveName(MainSurfaceDefaultsKeys.mainWindowFrameAutosaveName)
        windowFocusObservation = observeFocus(of: window, surface: .window)
        contentLayoutObservation = window.observe(\.contentLayoutRect) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.reportTopInset(of: window) }
        }
        return window
    }

    /// The root view of either surface: the shared layout plus the
    /// zero-size `SceneOpenerView` that hands over SwiftUI's `openWindow`
    /// for the ⌄ menu's Settings…. Both surfaces carry it,
    /// because either can be the first to appear after launch (the window
    /// form opens the window without the popover ever showing).
    static func surfaceRootView(
        model: MainSurfaceModel,
        surface: MainSurface,
        onSceneOpener: @escaping (@escaping (String) -> Void) -> Void
    ) -> some View {
        MainSurfaceView(model: model, textSize: model.textSize, surface: surface)
            .background(SceneOpenerView(onResolve: onSceneOpener))
    }

    /// §4.5: the pin changes the window level only.
    private func applyWindowLevel() {
        window?.level = model.keepOnTop ? .floating : .normal
    }

    /// Settings and the About panel float while the pin is ON
    /// and the window is open, so they open in front of the pinned window
    /// (`AuxiliaryWindowLevel`).
    /// `windowOpen` overrides the window's state for the close path: in
    /// `windowWillClose` the window is still on screen.
    private func applyAuxiliaryWindowLevels(windowOpen: Bool? = nil) {
        for window in NSApp.windows {
            applyAuxiliaryLevel(to: window, windowOpen: windowOpen)
        }
    }

    private func applyAuxiliaryLevel(to window: NSWindow, windowOpen: Bool? = nil) {
        let isAboutPanel = aboutPanel.map { $0 === window } ?? false
        guard AuxiliaryWindowLevel.isAuxiliary(title: window.title, isAboutPanel: isAboutPanel) else { return }
        let level = AuxiliaryWindowLevel.level(keepOnTop: model.keepOnTop, windowOpen: windowOpen ?? isWindowOpen)
        if window.level != level { window.level = level }
    }

    /// Shows the standard About panel (⌄ menu and app menu) with the pin's
    /// level. The panel is the window the call brings on screen (or, when it
    /// was already shown, the one remembered from before).
    private func showAboutPanel() {
        let visibleBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(nil)
        if let shown = NSApp.windows.first(where: { $0.isVisible && !visibleBefore.contains(ObjectIdentifier($0)) }) {
            aboutPanel = shown
        }
        if let aboutPanel {
            applyAuxiliaryLevel(to: aboutPanel)
        }
    }

    /// §9: the minimum content size of the window.
    static let minimumContentSize = NSSize(width: MainWindowMetrics.minimumWidth, height: MainWindowMetrics.minimumHeight)

    /// The frame size of `minimumContentSize` for this window's style.
    private static func minimumFrameSize(of window: NSWindow) -> NSSize {
        window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
    }

    /// §9: a user resize never goes below the minimum size.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === window else { return frameSize }
        return MainWindowMetrics.clampedFrameSize(frameSize, minimumFrameSize: Self.minimumFrameSize(of: sender))
    }

    /// A frame smaller than the minimum (a remembered one) grows to it,
    /// keeping the top-left corner.
    private func raiseFrameToMinimum(_ window: NSWindow) {
        let frame = MainWindowMetrics.frameRaisedToMinimum(window.frame, minimumFrameSize: Self.minimumFrameSize(of: window))
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    // MARK: - Full screen

    /// The layout switches as the transition starts, so the header row
    /// already has its full-screen form while the window grows and no
    /// change is left for the moment the animation ends. The toolbar is
    /// hidden for the same span: in full screen the system draws it as an
    /// opaque band over the header row.
    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window, (notification.object as? NSWindow) === window else { return }
        applyFullScreen(true, to: window, settled: false)
    }

    /// The title bar over the content is measured once the window has its
    /// full-screen frame.
    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window, (notification.object as? NSWindow) === window else { return }
        applyFullScreen(true, to: window, settled: true)
    }

    /// The windowed layout and the toolbar come back as the transition
    /// starts: the traffic lights reappear at the end of it at the height
    /// of the unified title bar, with their space already in the header
    /// row. Restoring them after the exit would move the traffic lights
    /// and the header row once the window is back.
    func windowWillExitFullScreen(_ notification: Notification) {
        guard let window, (notification.object as? NSWindow) === window else { return }
        applyFullScreen(false, to: window, settled: false)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard window === self.window else { return }
        applyFullScreen(false, to: window, settled: false)
    }

    /// The window stays in full screen: back to its full-screen form.
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard window === self.window else { return }
        applyFullScreen(true, to: window, settled: true)
    }

    /// The window's current full-screen state, read from its style mask
    /// (outside a transition).
    private func syncFullScreenState(of window: NSWindow) {
        let fullScreen = window.styleMask.contains(.fullScreen)
        applyFullScreen(fullScreen, to: window, settled: fullScreen)
    }

    private func applyFullScreen(_ fullScreen: Bool, to window: NSWindow, settled: Bool) {
        fullScreenSettled = fullScreen && settled
        if let toolbar = window.toolbar, toolbar.isVisible == fullScreen {
            toolbar.isVisible = !fullScreen
        }
        model.windowFullScreenChanged(fullScreen)
        reportTopInset(of: window)
    }

    private func reportTopInset(of window: NSWindow) {
        guard let contentView = window.contentView else { return }
        model.windowTopInsetChanged(WindowFullScreenInset.topInset(
            fullScreen: fullScreenSettled,
            contentHeight: Double(contentView.bounds.height),
            contentLayoutHeight: Double(window.contentLayoutRect.height)))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window, (notification.object as? NSWindow) === window else { return }
        becameKeyAt[.window] = ProcessInfo.processInfo.systemUptime
        if skipNextWindowKey {
            skipNextWindowKey = false
        } else {
            // §4.6: index -> search when the window becomes key.
            model.windowDidBecomeKey()
        }
        // After the refetch trigger: a window that was not on screen counts
        // as shown there, so this report is not dropped.
        model.surfaceKeyChanged(surface: .window, isKey: true)
        runPendingListFocus(pendingListFocus.windowBecameKey(at: ProcessInfo.processInfo.systemUptime))
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        model.surfaceKeyChanged(surface: .window, isKey: false)
    }

    /// Every close of the window comes here (the red button, ⌘W, the tray
    /// click and the hotkey on a frontmost window, `Open in popover`). The
    /// surface form stays as it is (§4.5 "surface form").
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        pendingListFocus.clear()
        fullScreenSettled = false
        model.surfaceDidHide(.window)
        state.noteRegularWindowClosed(forOpenInPopover: closingWindowForPopover)
        // With the window closed they go back to the normal level.
        applyAuxiliaryWindowLevels(windowOpen: false)
    }

    /// App menu Close Window (§4.5): the popover closes while it is key;
    /// otherwise the key window closes.
    private func closeKeySurface() {
        if let popoverWindow, popoverWindow.isKeyWindow {
            closePopover()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    // MARK: - Focus (§4.5 "key operations")

    private func observeFocus(of window: NSWindow, surface: MainSurface) -> NSKeyValueObservation {
        reportFocus(of: window, surface: surface)
        return window.observe(\.firstResponder) { [weak self] window, _ in
            MainActor.assumeIsolated {
                // Read the focus once the change has settled: a click on the
                // search field makes its field editor the first responder
                // before the editor's delegate is the field, so a read inside
                // this callback sees "not the search field" (measured with a
                // real click on an offscreen window).
                DispatchQueue.main.async { [weak self, weak window] in
                    MainActor.assumeIsolated {
                        guard let self, let window else { return }
                        self.reportFocus(of: window, surface: surface)
                    }
                }
            }
        }
    }

    private func reportFocus(of window: NSWindow, surface: MainSurface) {
        model.searchFieldFocusChanged(surface: surface, focused: Self.isSearchFieldFocused(in: window))
    }

    // MARK: - Key status (§4.5 "row selection")

    /// The popover's window: report its key status now and whenever it
    /// changes while the popover is shown.
    private func observeKeyStatus(ofPopoverWindow popoverWindow: NSWindow) {
        removePopoverKeyObservers()
        if popoverWindow.isKeyWindow {
            becameKeyAt[.popover] = ProcessInfo.processInfo.systemUptime
        }
        model.surfaceKeyChanged(surface: .popover, isKey: popoverWindow.isKeyWindow)
        let center = NotificationCenter.default
        popoverKeyObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: popoverWindow, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.becameKeyAt[.popover] = ProcessInfo.processInfo.systemUptime
                    self?.model.surfaceKeyChanged(surface: .popover, isKey: true)
                }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: popoverWindow, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.surfaceKeyChanged(surface: .popover, isKey: false) }
            },
        ]
    }

    private func removePopoverKeyObservers() {
        popoverKeyObservers.forEach(NotificationCenter.default.removeObserver)
        popoverKeyObservers = []
    }

    /// Which surface a window belongs to (nil: neither).
    private func surface(of eventWindow: NSWindow?) -> MainSurface? {
        guard let eventWindow else { return nil }
        if let window, eventWindow === window { return .window }
        if let popoverWindow, eventWindow === popoverWindow { return .popover }
        return nil
    }

    /// §4.5 "row click" / "row double-click": snapshot the surface's key
    /// status, the search field's focus, the system click count and the
    /// press time as the button goes down. The monitor runs before the
    /// event is dispatched to the window, so neither the click's own first
    /// responder change nor (for a click inside the app) its key change has
    /// happened yet; a key status gained by the activation of an inactive
    /// app is told apart by the press's timestamp (`SurfaceKeyAtPress`).
    /// The event always continues unchanged.
    private func setUpMouseDownMonitor() {
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.noteMouseDown(event)
            return event
        }
    }

    func noteMouseDown(_ event: NSEvent) {
        guard let eventWindow = event.window, let surface = surface(of: eventWindow) else { return }
        let wasKey = SurfaceKeyAtPress.wasKey(
            isKeyNow: eventWindow.isKeyWindow,
            becameKeyAt: becameKeyAt[surface],
            pressedAt: event.timestamp)
        model.pointerDown(
            surface: surface,
            surfaceWasKey: wasKey,
            searchFieldFocused: Self.isSearchFieldFocused(in: eventWindow),
            clickCount: event.clickCount,
            pressedAt: event.timestamp,
            commandKey: event.modifierFlags.contains(.command))
    }

    private func surfaceWindow(_ surface: MainSurface) -> NSWindow? {
        switch surface {
        case .popover: return popoverWindow
        case .window: return isWindowOpen ? window : nil
        }
    }

    /// "Focus the list": the search field resigns first responder (the
    /// window itself takes it), so the field shows no caret. Keys keep
    /// arriving at the key monitor. A surface that is not key becomes key
    /// (§4.5 "row click" on a gray selected row).
    private func focusList(on surface: MainSurface) {
        guard let window = surfaceWindow(surface) else { return }
        if !window.isKeyWindow, window.canBecomeKey {
            window.makeKey()
        }
        guard Self.isSearchFieldFocused(in: window) else { return }
        window.makeFirstResponder(nil)
    }

    /// A heading click (§4.5 "collapsing sections"): the surface becomes
    /// key with its first responder unchanged.
    private func makeKey(_ surface: MainSurface) {
        guard let window = surfaceWindow(surface) else { return }
        Self.makeKeyKeepingFocus(window)
    }

    /// Makes `window` key (when it is not and can be) without touching its
    /// first responder or activating the app.
    static func makeKeyKeepingFocus(_ window: NSWindow) {
        guard !window.isKeyWindow, window.canBecomeKey else { return }
        window.makeKey()
    }

    /// The search field has focus: it (or its field editor) is the first
    /// responder.
    static func isSearchFieldFocused(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder is SearchTextField { return true }
        if let editor = responder as? NSText, (editor.delegate as AnyObject?) is SearchTextField { return true }
        return false
    }

    /// Whether the first responder is a view that takes typed text or uses
    /// typing keys itself: a text view (another text field's editor) or a
    /// view inside the conversation pane's web view (Space scrolls it).
    /// Otherwise — the list has focus with the window itself as the first
    /// responder — typing reaches no view and AppKit would beep.
    static func focusedViewTakesTyping(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder, responder !== window else { return false }
        if responder is NSText { return true }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    // MARK: - Keys (§4.5 "key operations")

    private func setUpKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Handles keys for the popover's window and the main window only,
    /// before the focused view (the search field included).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let surface = surface(of: event.window) else { return false }
        // Marked text: every key belongs to the input method (§4.5).
        let hasMarkedText = (event.window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        let searchFieldFocused = event.window.map(Self.isSearchFieldFocused(in:)) ?? false
        let key = Self.listKey(for: event)
        let modifiers = Self.modifiers(of: event)
        switch model.handleKey(
            key: key,
            modifiers: modifiers,
            surface: surface,
            hasMarkedText: hasMarkedText,
            searchFieldFocused: searchFieldFocused
        ) {
        case .passThrough:
            // Typing with list focus does nothing (§4.5); a focused view that
            // takes it (the conversation pane: Space scrolls) still gets it,
            // and nothing else answers with the beep.
            if !searchFieldFocused, !hasMarkedText,
               UnifiedListKeys.isTyping(key: key, modifiers: modifiers),
               let window = event.window, !Self.focusedViewTakesTyping(in: window) {
                return true
            }
            return false
        case .passToConversationPane:
            // ↑ / ↓ on the one-column detail page scroll the conversation
            // (§4.5) whatever had focus (a header or bottom-panel button
            // click, the window itself): the web view becomes the first
            // responder before the event continues, so AppKit delivers it
            // there. Without the web view in this window, swallow (no beep).
            guard let window = event.window else { return true }
            let webView = model.webPane.webView
            guard webView.window === window else { return true }
            if !Self.responder(window.firstResponder, isInside: webView) {
                window.makeFirstResponder(webView)
            }
            return false
        case .consumed:
            return true
        }
    }

    /// Whether `responder` is `view` or a view inside it (WebKit's content
    /// view takes first responder inside the web view).
    static func responder(_ responder: NSResponder?, isInside view: NSView) -> Bool {
        guard let responderView = responder as? NSView else { return false }
        return responderView === view || responderView.isDescendant(of: view)
    }

    static func listKey(for event: NSEvent) -> ListKey {
        switch event.keyCode {
        case 126: return .upArrow
        case 125: return .downArrow
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 36, 76: return .returnKey
        case 53: return .escape
        case 51, 117: return .delete
        default: return .other(charactersIgnoringModifiers: event.charactersIgnoringModifiers)
        }
    }

    /// Only command / shift / option / control (arrow keys always carry
    /// `.function` / `.numericPad`).
    static func modifiers(of event: NSEvent) -> ListKeyModifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var result: ListKeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    // MARK: - ⌄ menu (§4.5)

    private func presentMenu(anchor: NSView, surface: MainSurface) {
        menuHandler.surface = surface
        menuHandler.openedWindow = false
        // The titles and enabled flags are decided now, from the state at
        // the moment the menu opens, and do not change while it is open
        // (§4.5 "⌄ menu").
        let menu = menuHandler.menu(for: HeaderMenu.entries(
            hasUnreviewed: state.hasUnreviewed,
            hasArchived: !model.list.archived.isEmpty,
            showsArchive: model.list.isArchiveView))
        guard let hostWindow = anchor.window else { return }
        let screenRect = hostWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        menu.popUp(positioning: nil, at: NSPoint(x: screenRect.minX, y: screenRect.minY - 4), in: nil)
        // popUp returns when the menu closes (the chosen item's action has
        // run by then); hand key status back — unless that item opened
        // another window, which must stay key and frontmost.
        if !menuHandler.openedWindow, hostWindow.isVisible { hostWindow.makeKey() }
    }

    // MARK: - A row's more-button menu (§4.6 "Archive")

    /// Opens the OS's standard menu at the more button, its right edge on
    /// the button's right edge and its top just below the button. Opened on
    /// the next main-queue turn, so the button's open-menu ground (set as
    /// the menu is requested) is drawn first. `completion` gets the chosen
    /// command, or nil when the menu closes without a choice; then the
    /// surface's window takes key status back.
    private func presentRowMenu(items: [RowMenuItem], anchor: NSView,
                                completion: @escaping @MainActor (RowMenuCommand?) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let hostWindow = anchor.window, hostWindow.isVisible else { return completion(nil) }
                let handler = RowMenuHandler()
                let menu = handler.menu(for: items)
                let rect = hostWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                menu.popUp(positioning: nil,
                           at: RowMenuPlacement.origin(anchorScreenRect: rect, menuWidth: menu.size.width),
                           in: nil)
                // popUp returns when the menu closes, after the chosen item's
                // action has run.
                completion(handler.chosen)
                if hostWindow.isVisible { hostWindow.makeKey() }
            }
        }
    }

    fileprivate func showAbout(from surface: MainSurface) {
        if surface == .popover { closePopover() }
        NSApp.activate(ignoringOtherApps: true)
        showAboutPanel()
    }

    fileprivate func openSettings(from surface: MainSurface) {
        if surface == .popover { closePopover() }
        NSApp.activate(ignoringOtherApps: true)
        let title = SettingsWindow.title
        state.settingsWindow.open { [weak self] id in self?.openSceneWindow?(id) }
        // `openWindow` can create the window after this call returns, and
        // re-opening an existing one does not always make it key: on the
        // next turn, bring the scene's window to the front as key.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) {
                    // Before the raise, so it comes up in front of a pinned
                    // window.
                    self?.applyAuxiliaryLevel(to: window)
                    Self.raise(window)
                }
            }
        }
    }

    fileprivate var appState: AppState { state }

    fileprivate func archivedMenuItemChosen() { model.archivedMenuItemChosen() }
}

/// The window level of the auxiliary windows — Settings and the About
/// panel (§4.5 "pin (Keep on Top)", §8.62): floating while the pin is ON
/// and the main window is open (minimized counts as open), so they open in
/// front of the pinned window; normal while the pin is OFF or the main
/// window is closed (the popover form included). The main window's own
/// level is `applyWindowLevel`'s.
enum AuxiliaryWindowLevel {
    static func level(keepOnTop: Bool, windowOpen: Bool) -> NSWindow.Level {
        keepOnTop && windowOpen ? .floating : .normal
    }

    /// Settings by its scene title; the About panel by the handle taken
    /// when it was shown.
    static func isAuxiliary(title: String, isAboutPanel: Bool) -> Bool {
        isAboutPanel || title == SettingsWindow.title
    }
}

/// The space the main window's content leaves at its top for a title bar
/// the system keeps over it in full screen (for example while the menu bar
/// stays shown in full screen): the part of the content view that
/// `contentLayoutRect` excludes, never negative. Outside full screen it is
/// 0, because the layout draws the header row under the hidden title bar on
/// purpose (`SurfaceMetrics.windowTrafficLightCenter`).
enum WindowFullScreenInset {
    static func topInset(fullScreen: Bool, contentHeight: Double, contentLayoutHeight: Double) -> Double {
        guard fullScreen else { return 0 }
        return max(0, contentHeight - contentLayoutHeight)
    }
}

/// What started a tray-click branch (§4.5 "tray icon click" / "global
/// hotkey").
enum SurfaceToggleSource: Equatable {
    case trayClick
    case hotKey
}

/// Where the keyboard focus goes after a tray click or a hotkey press opens
/// or raises a surface (§4.5 "popover" / "window" / "global hotkey").
enum SurfaceToggleFocus: Equatable {
    /// The focus of a surface opened by a tray click: the search field on
    /// the one-column list page and in two columns, the conversation pane on
    /// the one-column detail page (`MainSurfaceModel.requestInitialFocus`).
    case initial
    /// The list (`MainSurfaceModel.openedByHotKey`).
    case list

    /// The focus to request after `action`; nil = leave the focus as it is
    /// (a window raised by a tray click, or a surface that closes).
    static func after(_ action: SurfaceToggleAction, source: SurfaceToggleSource) -> SurfaceToggleFocus? {
        switch action {
        case .openPopover, .openWindow:
            return source == .hotKey ? .list : .initial
        case .raiseWindow:
            return source == .hotKey ? .list : nil
        case .closePopover, .closeWindow:
            return nil
        }
    }
}

/// Closes the popover when the app resigns active (DESIGN.md §4.5 "popover"
/// close triggers, §8.58): once an `NSMenu` has been opened from inside a
/// `.transient` popover, AppKit no longer closes the popover when another
/// app becomes active, but `NSApplication.didResignActiveNotification` is
/// still posted. The window is never closed here. The notification center
/// is injected so tests post the notification themselves.
@MainActor
final class PopoverDeactivationCloser {
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter, isPopoverShown: @escaping @MainActor () -> Bool, closePopover: @escaping @MainActor () -> Void) {
        self.center = center
        // No queue: the block runs synchronously on the posting thread,
        // which is the main thread for AppKit's activation notifications.
        observer = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                if isPopoverShown() { closePopover() }
            }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }
}

/// One entry of the ⌄ menu (§4.5 "⌄ menu").
enum HeaderMenuEntry: Equatable {
    case item(HeaderMenuItem)
    case separator
}

struct HeaderMenuItem: Equatable {
    enum Command: Equatable {
        case about
        case settings
        case archived
        case markAllAsRead
        case quit
    }

    let command: Command
    let title: String
    let isEnabled: Bool
    /// Shown with a check mark.
    var isChecked = false
}

/// The ⌄ menu's entries (§4.5 "⌄ menu"): About Shiibar CC / — / Settings… /
/// — / Archived / Mark all as read / — / Quit. Setup Check is a tab of the
/// Settings window; Refresh is the header row's button and ⌘R.
enum HeaderMenu {
    /// The state when the menu opens: Mark all as read is disabled when
    /// nothing is unreviewed (§8.24); `Archived` is disabled while no conversation
    /// is archived (`hasArchived`: the stored archived list, not waiting
    /// for a search result) and checked while the Archive view is shown
    /// (`showsArchive`).
    static func entries(hasUnreviewed: Bool, hasArchived: Bool, showsArchive: Bool) -> [HeaderMenuEntry] {
        [
            .item(HeaderMenuItem(command: .about, title: "About Shiibar CC", isEnabled: true)),
            .separator,
            .item(HeaderMenuItem(command: .settings, title: "Settings\u{2026}", isEnabled: true)),
            .separator,
            .item(HeaderMenuItem(command: .archived, title: "Archived", isEnabled: hasArchived,
                                 isChecked: showsArchive)),
            .item(HeaderMenuItem(command: .markAllAsRead, title: "Mark all as read", isEnabled: hasUnreviewed)),
            .separator,
            .item(HeaderMenuItem(command: .quit, title: "Quit", isEnabled: true)),
        ]
    }
}

/// NSMenu action target for the ⌄ menu (NSMenuItem.target is weak).
@MainActor
final class HeaderMenuHandler: NSObject {
    weak var controller: MainSurfaceController?
    var surface: MainSurface = .popover
    /// Set by the items that open another window (About / Settings) while
    /// the menu is open.
    var openedWindow = false

    init(controller: MainSurfaceController?) {
        self.controller = controller
    }

    /// The menu for `entries`, its items targeting this handler. The
    /// enabled flags are set by hand (no automatic validation), so they keep
    /// the values of the moment the menu was built.
    func menu(for entries: [HeaderMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                let menuItem = NSMenuItem(title: item.title, action: Self.selector(for: item.command), keyEquivalent: "")
                menuItem.target = self
                menuItem.isEnabled = item.isEnabled
                menuItem.state = item.isChecked ? .on : .off
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    private static func selector(for command: HeaderMenuItem.Command) -> Selector {
        switch command {
        case .about: return #selector(showAbout(_:))
        case .settings: return #selector(openSettings(_:))
        case .archived: return #selector(toggleArchived(_:))
        case .markAllAsRead: return #selector(markAllAsRead(_:))
        case .quit: return #selector(quit(_:))
        }
    }

    @objc func showAbout(_ sender: Any?) {
        openedWindow = true
        controller?.showAbout(from: surface)
    }
    @objc func openSettings(_ sender: Any?) {
        openedWindow = true
        controller?.openSettings(from: surface)
    }
    @objc func toggleArchived(_ sender: Any?) { controller?.archivedMenuItemChosen() }
    @objc func markAllAsRead(_ sender: Any?) { controller?.appState.markAllAsRead() }
    @objc func quit(_ sender: Any?) { controller?.appState.quit() }
}

/// Where a row's more-button menu opens (§4.6 "Archive"): the menu's
/// top-left corner in screen coordinates (y up), so its right edge lines up
/// with the button's right edge and its top sits 4pt below the button.
enum RowMenuPlacement {
    static let gapBelowButton: CGFloat = 4

    static func origin(anchorScreenRect rect: NSRect, menuWidth: CGFloat) -> NSPoint {
        NSPoint(x: rect.maxX - menuWidth, y: rect.minY - gapBelowButton)
    }
}

/// NSMenu action target for a row's more-button menu (§4.6 "Archive").
/// Builds the menu from the items' values and records the chosen command.
@MainActor
final class RowMenuHandler: NSObject {
    /// The command of the item chosen while the menu was open.
    private(set) var chosen: RowMenuCommand?
    private var commands: [RowMenuCommand] = []

    /// The menu for `items`, its items targeting this handler. The enabled
    /// flags are set by hand (no automatic validation), so they keep the
    /// values of the moment the menu opened.
    func menu(for items: [RowMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        commands = items.map(\.command)
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menuItem.isEnabled = item.isEnabled
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard commands.indices.contains(sender.tag) else { return }
        chosen = commands[sender.tag]
    }
}

/// The opaque ground behind the popover's content and arrow. The color is
/// resolved in `updateLayer`, so it follows the light / dark appearance.
final class PopoverBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// AppKit makes this view's effective appearance the current drawing
    /// appearance before calling `updateLayer` (NSAppearance.h), so the
    /// dynamic color resolves to the popover's light or dark value.
    override func updateLayer() {
        layer?.backgroundColor = SurfaceColors.listBackgroundNSColor.cgColor
    }

    /// A `CGColor` does not follow appearance changes on its own: re-resolve
    /// it when the popover switches between light and dark.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The popover's bottom-edge drag area (§4.5 / §9): 8pt tall, nothing
/// drawn, an up/down resize cursor; it receives the mouse before the
/// content under it. The drag delta is read in screen coordinates (moving
/// down grows the popover).
final class PopoverResizeStrip: NSView {
    var onBegin: () -> Void = {}
    var onDrag: (Double) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private var startY: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startY = NSEvent.mouseLocation.y
        onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag(Double(startY - NSEvent.mouseLocation.y))
    }

    override func mouseUp(with event: NSEvent) {
        onEnd()
    }
}

/// `NSHostingView` that accepts the first mouse, so rows and their buttons
/// react to the click that also activates an unfocused window (§4.5
/// click-through).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Captures SwiftUI's `openWindow` action so AppKit code (the ⌄ menu) can
/// open the Settings `Window` scene.
struct SceneOpenerView: View {
    let onResolve: (@escaping (String) -> Void) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let action = openWindow
                onResolve { id in action(id: id) }
            }
    }
}
