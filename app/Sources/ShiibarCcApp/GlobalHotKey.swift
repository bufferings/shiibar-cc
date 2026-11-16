// The global hotkey (DESIGN.md §4.5 "global hotkey", §8.50): the system
// registration through Carbon's `RegisterEventHotKey` (no Accessibility
// permission; the registered combination no longer reaches the frontmost
// app), and the model that runs `GlobalShortcutRecorder` (Core) for the
// Settings window's Global shortcut field. The registrar is a protocol so
// tests use a spy and never register a real hotkey; UserDefaults is
// injected so tests never touch the standard domain.

import AppKit
import Carbon.HIToolbox
import Combine
import os
import ShiibarCcCore

private let hotKeyLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc.shiibar.menubar",
    category: "hotkey"
)

/// Registers one system-wide hotkey at a time.
@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    /// Called on the main actor each time the registered combination is
    /// pressed.
    var onPressed: () -> Void { get set }
    /// Register `shortcut`, replacing the current registration if any.
    /// Returns false when the system refuses it (nothing is registered then).
    func register(_ shortcut: GlobalShortcut) -> Bool
    /// Remove the registration (no-op when none).
    func unregister()
}

/// The production registrar: Carbon `RegisterEventHotKey` on the
/// application event target. The pressed handler is installed once, on the
/// first registration.
@MainActor
final class CarbonHotKeyRegistrar: GlobalHotKeyRegistering {
    var onPressed: () -> Void = {}
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// "SHCC": this app's hotkey signature.
    private static let signature: OSType = 0x5348_4343

    func register(_ shortcut: GlobalShortcut) -> Bool {
        unregister()
        guard installHandlerIfNeeded() else { return false }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref)
        guard status == noErr, let ref else {
            hotKeyLog.error("RegisterEventHotKey failed: \(status, privacy: .public) for \(shortcut.displayString, privacy: .public)")
            return false
        }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        guard let hotKeyRef else { return }
        let status = UnregisterEventHotKey(hotKeyRef)
        if status != noErr {
            hotKeyLog.error("UnregisterEventHotKey failed: \(status, privacy: .public)")
        }
        self.hotKeyRef = nil
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                // The application event target dispatches on the main thread.
                MainActor.assumeIsolated { registrar.onPressed() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)
        if status != noErr {
            hotKeyLog.error("InstallEventHandler failed: \(status, privacy: .public)")
            return false
        }
        return true
    }

    /// Carbon modifier bits (`cmdKey` / `shiftKey` / `optionKey` /
    /// `controlKey`, HIToolbox `Events.h`).
    static func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}

/// Runs the Global shortcut state machine (`GlobalShortcutRecorder`) against
/// the registrar and UserDefaults. The Settings field renders from it; the
/// pressed hotkey goes to `onPressed` (the surface controller's toggle).
@MainActor
final class GlobalHotKeyModel: ObservableObject {
    @Published private(set) var recorder = GlobalShortcutRecorder()

    private let registrar: GlobalHotKeyRegistering
    private let defaults: UserDefaults
    private var started = false

    /// The hotkey was pressed (set by `MainSurfaceController`).
    var onPressed: () -> Void = {}

    init(registrar: GlobalHotKeyRegistering, defaults: UserDefaults) {
        self.registrar = registrar
        self.defaults = defaults
        registrar.onPressed = { [weak self] in self?.onPressed() }
    }

    /// Register the stored combination (app launch). A failed registration
    /// keeps the stored value and runs unregistered (M45 T1).
    func start() {
        guard !started else { return }
        started = true
        let stored = GlobalShortcutCodec.decode(defaults.object(forKey: GlobalShortcutCodec.defaultsKey))
        send(.launched(stored: stored))
    }

    func fieldClicked() { send(.fieldClicked) }

    func keyPressed(keyCode: UInt16, modifiers: ShortcutModifiers, keyName: String?) {
        send(.keyPressed(keyCode: keyCode, modifiers: modifiers, keyName: keyName))
    }

    func recordingAbandoned() { send(.recordingAbandoned) }

    func clearClicked() { send(.clearClicked) }

    private func send(_ event: GlobalShortcutRecorderEvent) {
        var state = recorder
        var queue = state.handle(event)
        while !queue.isEmpty {
            let effect = queue.removeFirst()
            switch effect {
            case .register(let shortcut):
                let succeeded = registrar.register(shortcut)
                queue.append(contentsOf: state.handle(.registrationFinished(succeeded: succeeded)))
            case .unregister:
                registrar.unregister()
            case .persist(let shortcut):
                if let shortcut {
                    defaults.set(GlobalShortcutCodec.encode(shortcut), forKey: GlobalShortcutCodec.defaultsKey)
                } else {
                    defaults.removeObject(forKey: GlobalShortcutCodec.defaultsKey)
                }
            }
        }
        if state != recorder { recorder = state }
    }

    /// The modifiers of a key event as a shortcut's modifiers.
    static func modifiers(of flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: ShortcutModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    /// The name of a key event's key (§4.5: the character the current
    /// keyboard layout types for it, without modifiers).
    static func keyName(of event: NSEvent) -> String? {
        ShortcutKeys.keyName(keyCode: event.keyCode, characters: event.characters(byApplyingModifiers: []))
    }
}
