import AppKit
import ShiibarCcCore
import SwiftUI
import XCTest
@testable import ShiibarCcApp

/// The Global shortcut field (DESIGN.md §4.5 "Settings window" > General >
/// Global shortcut) hosted the way the Settings window hosts it — in the
/// General tab's row — in a real titled window placed far offscreen, driven by
/// real mouse and key `NSEvent`s through the application's event path. A
/// spy registrar and in-memory defaults: no real hotkey is registered and
/// `UserDefaults.standard` is never written.
@MainActor
final class GlobalShortcutFieldClickTests: XCTestCase {
    private final class SpyRegistrar: GlobalHotKeyRegistering {
        var onPressed: () -> Void = {}
        var calls: [String] = []

        func register(_ shortcut: GlobalShortcut) -> Bool {
            calls.append("register \(shortcut.displayString)")
            return true
        }

        func unregister() {
            calls.append("unregister")
        }
    }

    /// Stays where it is put (no constraining onto a screen).
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private let cmdShiftK = GlobalShortcut(keyCode: 0x28, modifiers: [.shift, .command], keyName: "K")
    private var registrar = SpyRegistrar()
    private var defaults = InMemoryDefaults()
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        registrar = SpyRegistrar()
        defaults = InMemoryDefaults()
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private var storedValue: GlobalShortcut? {
        GlobalShortcutCodec.decode(defaults.object(forKey: GlobalShortcutCodec.defaultsKey))
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The model started (app launch) and the General tab hosted as the
    /// Settings window shows it; returns the field's input view.
    private func host(stored: GlobalShortcut? = nil) throws -> (GlobalHotKeyModel, ShortcutFieldInputView) {
        if let stored {
            defaults.set(GlobalShortcutCodec.encode(stored), forKey: GlobalShortcutCodec.defaultsKey)
        }
        let model = GlobalHotKeyModel(registrar: registrar, defaults: defaults)
        model.start()
        let settings = SettingsViewModel(
            notificationManager: NotificationManager(),
            loginItemEnabledProvider: { false },
            toggleLoginItem: {},
            appearanceSetting: .system,
            setAppearance: { _ in },
            availableSoundNames: ["Glass"])
        let textSizeField = TextSizeFieldModel(store: TextSizeStore(defaults: defaults))
        let windowModel = SettingsWindowModel(
            general: settings, textSizeField: textSizeField, hotKey: model,
            setupCheck: SetupCheckViewModel(performChecks: { _ in }),
            resumeTerminal: ResumeTerminalSetting(defaults: defaults, lookup: { _ in nil }, center: NotificationCenter()),
            center: NotificationCenter())
        let root = SettingsTabContent(model: windowModel)
            .frame(width: SettingsLayout.windowWidth)
            .fixedSize(horizontal: false, vertical: true)
        let window = OffscreenWindow(
            contentRect: NSRect(x: -40000, y: -40000, width: SettingsLayout.windowWidth, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // ARC holds the reference (release-on-close double-frees under XCTest).
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        window.orderFrontRegardless()
        self.window = window
        pump()
        XCTAssertLessThan(window.frame.maxX, -30000, "the window must stay offscreen")
        let input = try XCTUnwrap(Self.find(ShortcutFieldInputView.self, in: try XCTUnwrap(window.contentView)))
        return (model, input)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    /// The view a click at `point` (window coordinates) is delivered to.
    private func hitView(at point: NSPoint) throws -> NSView? {
        let frameView = try XCTUnwrap(window?.contentView?.superview)
        return frameView.hitTest(frameView.convert(point, from: nil))
    }

    /// Posts `event` and dispatches the queue the way the app's run loop does
    /// (`nextEvent` then `sendEvent`), so local event monitors see it.
    private func deliver(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: false)
        while let next = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
        }
        pump(0.1)
    }

    private func click(at point: NSPoint) throws {
        let window = try XCTUnwrap(window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            deliver(event)
        }
    }

    private func press(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String) throws {
        let window = try XCTUnwrap(window)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
        deliver(event)
    }

    /// The field's rectangle in window coordinates.
    private func fieldFrame(_ input: ShortcutFieldInputView) -> NSRect {
        input.convert(input.bounds, to: nil)
    }

    // MARK: - Tests

    /// A click on the field's text (`Record Shortcut`, which covers most of
    /// the field) starts recording; a text interaction view over the text
    /// must not take it.
    func testClickOnTheFieldTextStartsRecording() throws {
        let (model, input) = try host()
        XCTAssertEqual(model.recorder.fieldText, GlobalShortcutRecorder.recordText)
        let frame = fieldFrame(input)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        XCTAssertTrue(try hitView(at: point) === input, "the field's input view must receive the click on the text")

        try click(at: point)

        XCTAssertTrue(model.recorder.isRecording)
        XCTAssertEqual(model.recorder.fieldText, GlobalShortcutRecorder.recordingText)
        XCTAssertEqual(registrar.calls, [], "nothing was registered, so nothing to suspend")
    }

    /// A click on the field's padding (beside the text) starts recording too.
    func testClickOnTheFieldPaddingStartsRecording() throws {
        let (model, input) = try host()
        let frame = fieldFrame(input)
        let point = NSPoint(x: frame.minX + 3, y: frame.midY)
        XCTAssertTrue(try hitView(at: point) === input)

        try click(at: point)

        XCTAssertTrue(model.recorder.isRecording)
    }

    /// While recording, ⌃⌥Space typed into the Settings window is recorded:
    /// registered and stored.
    func testKeyPressedWhileRecordingIsRegisteredAndStored() throws {
        let (model, input) = try host()
        let frame = fieldFrame(input)
        try click(at: NSPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(model.recorder.isRecording)

        try press(keyCode: 0x31, modifiers: [.control, .option], characters: " ")

        let expected = GlobalShortcut(keyCode: 0x31, modifiers: [.control, .option], keyName: "Space")
        XCTAssertFalse(model.recorder.isRecording)
        XCTAssertEqual(model.recorder.registered, expected)
        XCTAssertEqual(registrar.calls, ["register \u{2303}\u{2325}Space"])
        XCTAssertEqual(storedValue, expected)
    }

    /// A click on × clears the registered combination (unregistered and
    /// removed from the defaults) without starting a recording.
    func testClickOnClearButtonClearsTheRegisteredShortcut() throws {
        let (model, input) = try host(stored: cmdShiftK)
        XCTAssertEqual(model.recorder.registered, cmdShiftK)
        XCTAssertTrue(model.recorder.showsClearButton)
        registrar.calls = []
        let frame = fieldFrame(input)
        // The × button's center: the trailing padding (8pt) plus half the
        // symbol's width in from the field's trailing edge.
        let point = NSPoint(x: frame.maxX - 8 - 6, y: frame.midY)
        XCTAssertFalse(try hitView(at: point) === input, "× sits above the field's input view")

        try click(at: point)

        XCTAssertFalse(model.recorder.isRecording)
        XCTAssertNil(model.recorder.registered)
        XCTAssertEqual(registrar.calls, ["unregister"])
        XCTAssertNil(storedValue)
    }
}
