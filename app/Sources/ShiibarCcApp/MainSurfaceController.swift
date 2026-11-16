// The AppKit side of the two surfaces (DESIGN.md §4.5 "tray icon click" /
// "popover" / "window" / "key operations" / "⌄ menu" / "global hotkey",
// §8.49 / §8.50): the status item (drawn by `TrayIconRenderer`), the
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
    /// operations"), the key hints and the buttons' shortcut glyphs.
    private var popoverFocusObservation: NSKeyValueObservation?
    private var windowFocusObservation: NSKeyValueObservation?
    /// When the popover last closed: the status-item click that caused a
    /// transient close arrives right after it and must not reopen it.
    private var lastPopoverClose: Date = .distantPast
    private var heightDrag: PopoverHeightDrag?
    /// Set while a just-opened window's first key event is pending.
    private var skipNextWindowKey = false
    private var subscriptions: Set<AnyCancellable> = []
    /// Redraws the tray when the menu bar's appearance flips (the badge
    /// variant is not a template image and picks its glyph color by hand).
    private var appearanceObservation: NSKeyValueObservation?
    /// Skips tray image assignments that would depict the same thing (see
    /// `refreshTrayImage`).
    private var trayImageGate = TrayImageGate()
    /// Opens the Settings / Setup Check `Window` scenes (captured from a
    /// SwiftUI view — see `SceneOpenerView`).
    var openSceneWindow: ((String) -> Void)?
    private lazy var menuHandler = HeaderMenuHandler(controller: self)

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
        setUpKeyMonitor()
        setUpMouseDownMonitor()
        model.onClosePopover = { [weak self] in self?.closePopover() }
        model.onOpenInWindow = { [weak self] in self?.openWindow() }
        model.onPresentMenu = { [weak self] anchor, surface in self?.presentMenu(anchor: anchor, surface: surface) }
        model.onKeepOnTopChanged = { [weak self] _ in self?.applyWindowLevel() }
        model.onFocusList = { [weak self] surface in self?.focusList(on: surface) }
        state.closeKeySurface = { [weak self] in self?.closeKeySurface() }
        state.willOpenAuxiliaryWindow = { [weak self] in self?.closePopover() }
        state.raiseMainWindow = { [weak self] in self?.raiseWindow() }
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
    }

    private func refreshTrayImage() {
        guard let button = statusItem?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let icon = state.trayIcon
        // Assign only when the depicted state or the menu bar appearance
        // changed: setting the image schedules a replicant redraw that sets
        // the button's appearance and re-fires `appearanceObservation`, so an
        // unconditional assignment never stops redrawing.
        guard trayImageGate.shouldRender(state: icon, darkMenuBar: dark) else { return }
        button.image = TrayIconRenderer.render(state: icon, darkMenuBar: dark)
    }

    /// The window is open: on screen or minimized to the Dock (closing
    /// orders it out; minimizing keeps it open).
    private var isWindowOpen: Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        toggleSurface(from: .trayClick)
    }

    /// The global hotkey was pressed (§4.5 "global hotkey"): the tray
    /// click's branch, with the list focused afterwards.
    func hotKeyPressed() {
        toggleSurface(from: .hotKey)
    }

    private enum ToggleSource {
        case trayClick
        case hotKey
    }

    /// §4.5 "tray icon click" / "global hotkey": with the window open
    /// (minimized included), bring it forward — no popover; otherwise the
    /// popover opens or closes (`SurfaceToggleAction`).
    private func toggleSurface(from source: ToggleSource) {
        switch SurfaceToggleAction.decide(windowOpen: isWindowOpen, popoverShown: popover.isShown) {
        case .raiseWindow:
            raiseWindow()
            if source == .hotKey { focusAfterHotKey() }
        case .closePopover:
            popover.performClose(nil)
        case .openPopover:
            // The click that just closed the transient popover (outside
            // click on the icon) must not reopen it.
            if source == .trayClick, Date().timeIntervalSince(lastPopoverClose) < 0.3 { return }
            showPopover(openedByHotKey: source == .hotKey)
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
        let size = NSSize(width: PopoverHeight.width, height: initialHeight)
        let hosting = NSHostingView(rootView: MainSurfaceView(model: model, surface: .popover)
            .background(SceneOpenerView { [weak self] open in self?.openSceneWindow = open }))
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
    }

    private func updateHeightDrag(delta: Double) {
        guard var drag = heightDrag else { return }
        let entered = drag.update(dragDelta: delta, maximum: maximumPopoverHeight())
        heightDrag = drag
        if entered {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        popover.contentSize = NSSize(width: PopoverHeight.width, height: drag.height)
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

    func showPopover(openedByHotKey: Bool = false) {
        guard let button = statusItem?.button else { return }
        // A remembered height above the maximum opens at the maximum; the
        // stored value itself stays (§9).
        let height = PopoverHeight.heightToOpen(stored: storedPopoverHeight(), maximum: maximumPopoverHeight())
        popover.contentSize = NSSize(width: PopoverHeight.width, height: height)
        model.surfaceDidShow(.popover)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installPopoverBackground()
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverFocusObservation = observeFocus(of: popoverWindow, surface: .popover)
            observeKeyStatus(ofPopoverWindow: popoverWindow)
        }
        if openedByHotKey {
            focusAfterHotKey()
        } else {
            model.requestInitialFocus()
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
    }

    private var popoverWindow: NSWindow? {
        popover.isShown ? popover.contentViewController?.view.window : nil
    }

    // MARK: - Window

    func openWindow() {
        closePopover()
        let window = self.window ?? makeWindow()
        self.window = window
        applyWindowLevel()
        if !isWindowOpen {
            state.noteRegularWindowOpened()
            // The open itself is the trigger (§4.6); the key event that
            // follows must not run index -> search a second time.
            skipNextWindowKey = true
            model.surfaceDidShow(.window)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        reportFocus(of: window, surface: .window)
        // Activation can complete later; `windowDidBecomeKey` reports then.
        model.surfaceKeyChanged(surface: .window, isKey: window.isKeyWindow)
        model.requestInitialFocus()
    }

    func raiseWindow() {
        guard let window, isWindowOpen else { return }
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
        window.contentMinSize = NSSize(width: MainWindowMetrics.minimumWidth, height: MainWindowMetrics.minimumHeight)
        window.delegate = self
        let hosting = FirstMouseHostingView(rootView: MainSurfaceView(model: model, surface: .window))
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
        return window
    }

    /// §4.5: the pin changes the window level only.
    private func applyWindowLevel() {
        window?.level = model.keepOnTop ? .floating : .normal
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
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        model.surfaceKeyChanged(surface: .window, isKey: false)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        model.surfaceDidHide(.window)
        state.noteRegularWindowClosed()
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
            pressedAt: event.timestamp)
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
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuHandler.item("About Shiibar CC", #selector(HeaderMenuHandler.showAbout(_:))))
        menu.addItem(.separator())
        menu.addItem(menuHandler.item("Settings\u{2026}", #selector(HeaderMenuHandler.openSettings(_:))))
        menu.addItem(menuHandler.item("Setup Check\u{2026}", #selector(HeaderMenuHandler.openSetupCheck(_:))))
        menu.addItem(.separator())
        menu.addItem(menuHandler.item("Rescan", #selector(HeaderMenuHandler.rescan(_:))))
        // §4.5 / §8.24: disabled when nothing is unreviewed.
        menu.addItem(menuHandler.item("Clear badges", #selector(HeaderMenuHandler.clearBadges(_:)), enabled: state.hasUnreviewed))
        menu.addItem(.separator())
        menu.addItem(menuHandler.item("Quit", #selector(HeaderMenuHandler.quit(_:))))
        guard let hostWindow = anchor.window else { return }
        let screenRect = hostWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        menu.popUp(positioning: nil, at: NSPoint(x: screenRect.minX, y: screenRect.minY - 4), in: nil)
        // popUp returns when the menu closes (the chosen item's action has
        // run by then); hand key status back — unless that item opened
        // another window, which must stay key and frontmost.
        if !menuHandler.openedWindow, hostWindow.isVisible { hostWindow.makeKey() }
    }

    fileprivate func showAbout(from surface: MainSurface) {
        if surface == .popover { closePopover() }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    fileprivate func openScene(_ id: String, title: String, from surface: MainSurface) {
        if surface == .popover { closePopover() }
        NSApp.activate(ignoringOtherApps: true)
        openSceneWindow?(id)
        // `openWindow` can create the window after this call returns, and
        // re-opening an existing one does not always make it key: on the
        // next turn, bring the scene's window to the front as key.
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) {
                Self.raise(window)
            }
        }
    }

    fileprivate var appState: AppState { state }
}

/// NSMenu action target for the ⌄ menu (NSMenuItem.target is weak).
@MainActor
private final class HeaderMenuHandler: NSObject {
    weak var controller: MainSurfaceController?
    var surface: MainSurface = .popover
    /// Set by the items that open another window (About / Settings / Setup
    /// Check) while the menu is open.
    var openedWindow = false

    init(controller: MainSurfaceController) {
        self.controller = controller
    }

    func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc func showAbout(_ sender: Any?) {
        openedWindow = true
        controller?.showAbout(from: surface)
    }
    @objc func openSettings(_ sender: Any?) {
        openedWindow = true
        controller?.openScene(SettingsWindow.id, title: SettingsWindow.title, from: surface)
    }
    @objc func openSetupCheck(_ sender: Any?) {
        openedWindow = true
        controller?.openScene(SetupCheckWindow.id, title: SetupCheckWindow.title, from: surface)
    }
    @objc func rescan(_ sender: Any?) { controller?.appState.runReconcile(showFeedback: true) }
    @objc func clearBadges(_ sender: Any?) { controller?.appState.clearBadges() }
    @objc func quit(_ sender: Any?) { controller?.appState.quit() }
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

    override func updateLayer() {
        layer?.backgroundColor = SurfaceColors.listBackgroundNSColor.cgColor
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
/// open the Settings / Setup Check `Window` scenes.
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
