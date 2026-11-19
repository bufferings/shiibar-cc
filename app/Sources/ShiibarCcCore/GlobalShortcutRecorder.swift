// The Settings window's Global shortcut field and the hotkey registration
// behind it (DESIGN.md §4.5 "global hotkey" / "Settings window" > General >
// Global shortcut, §8.50), as a value-type state machine: each event returns
// the side effects the app performs (register / unregister the system
// hotkey, persist the value). The app answers every `.register` effect with
// `.registrationFinished`.

import Foundation

public enum GlobalShortcutRecorderEvent: Equatable, Sendable {
    /// App launch with the stored value (`GlobalShortcutCodec.decode`; nil =
    /// none or unreadable).
    case launched(stored: GlobalShortcut?)
    /// A click on the field: recording starts.
    case fieldClicked
    /// A key pressed while recording. `keyName` is nil when the key has no
    /// usable name (`ShortcutKeys.keyName`).
    case keyPressed(keyCode: UInt16, modifiers: ShortcutModifiers, keyName: String?)
    /// Recording is abandoned without a key: a click outside the field, or
    /// the Settings window stops being key or closes.
    case recordingAbandoned
    /// The × button.
    case clearClicked
    /// The answer to a `.register` effect: whether the system accepted it.
    case registrationFinished(succeeded: Bool)
}

public enum GlobalShortcutRecorderEffect: Equatable, Sendable {
    /// Register this combination with the system (replacing nothing: the
    /// state machine unregisters first when needed). Answer with
    /// `.registrationFinished`.
    case register(GlobalShortcut)
    /// Remove the system registration.
    case unregister
    /// Write the value to UserDefaults (nil = remove it).
    case persist(GlobalShortcut?)
}

public struct GlobalShortcutRecorder: Equatable, Sendable {
    /// The combination registered with the system — or, while recording,
    /// the one registered before recording started (suspended, restored when
    /// recording ends without a new one). nil = unregistered.
    public private(set) var registered: GlobalShortcut?
    /// The field is recording (§4.5: shows `Type shortcut`).
    public private(set) var isRecording = false
    /// The line under the field; nil = none.
    public private(set) var hint: GlobalShortcutHint?
    /// The registration in flight (between a `.register` effect and its
    /// answer).
    private var pending: Pending?

    private enum Pending: Equatable, Sendable {
        /// The stored value at launch.
        case launch(GlobalShortcut)
        /// A combination pressed while recording.
        case recorded(GlobalShortcut)
        /// The registration from before recording, put back.
        case restore(GlobalShortcut)
    }

    public static let recordText = "Record Shortcut"
    public static let recordingText = "Type shortcut"

    public init() {}

    /// The field's text (§4.5).
    public var fieldText: String {
        if isRecording { return Self.recordingText }
        return registered?.displayString ?? Self.recordText
    }

    /// The × button is shown while a combination is registered and the field
    /// is not recording.
    public var showsClearButton: Bool { registered != nil && !isRecording }

    @discardableResult
    public mutating func handle(_ event: GlobalShortcutRecorderEvent) -> [GlobalShortcutRecorderEffect] {
        switch event {
        case .launched(let stored):
            guard let stored else { return [] }
            pending = .launch(stored)
            return [.register(stored)]

        case .fieldClicked:
            guard !isRecording, pending == nil else { return [] }
            isRecording = true
            hint = nil
            // §4.5: the registration is suspended while recording.
            return registered == nil ? [] : [.unregister]

        case .keyPressed(let keyCode, let modifiers, let keyName):
            guard isRecording, pending == nil else { return [] }
            // §4.5: Esc while recording cancels it.
            if keyCode == ShortcutKeys.escape {
                return endRecordingKeepingPrevious()
            }
            guard let keyName else { return [] }
            let candidate = GlobalShortcut(keyCode: keyCode, modifiers: modifiers, keyName: keyName)
            switch candidate.validation {
            case .needsModifier:
                // §4.5: still recording, with the hint under the field.
                hint = .addModifier
                return []
            case .valid:
                pending = .recorded(candidate)
                return [.register(candidate)]
            }

        case .recordingAbandoned:
            guard isRecording, pending == nil else { return [] }
            return endRecordingKeepingPrevious()

        case .clearClicked:
            guard registered != nil, !isRecording, pending == nil else { return [] }
            registered = nil
            hint = nil
            return [.unregister, .persist(nil)]

        case .registrationFinished(let succeeded):
            guard let current = pending else { return [] }
            pending = nil
            switch current {
            case .launch(let shortcut):
                // §4.5 / M45: a launch registration that fails keeps the
                // stored value and runs unregistered.
                registered = succeeded ? shortcut : nil
                return []
            case .recorded(let shortcut):
                isRecording = false
                if succeeded {
                    registered = shortcut
                    hint = nil
                    return [.persist(shortcut)]
                }
                // §4.5: the system refused it — keep the previous
                // registration and show the hint.
                hint = .alreadyInUse
                return restorePrevious()
            case .restore:
                if !succeeded {
                    registered = nil
                }
                return []
            }
        }
    }

    private mutating func endRecordingKeepingPrevious() -> [GlobalShortcutRecorderEffect] {
        isRecording = false
        hint = nil
        return restorePrevious()
    }

    private mutating func restorePrevious() -> [GlobalShortcutRecorderEffect] {
        guard let previous = registered else { return [] }
        pending = .restore(previous)
        return [.register(previous)]
    }
}

/// What the tray icon click and the global hotkey do with the surfaces
/// (§4.5 "tray icon click" / "global hotkey", §8.61). Decided in this order:
/// 1. the popover is shown: close it;
/// 2. the window is open (minimized included): close it when it is
///    frontmost, otherwise bring it forward;
/// 3. neither: open the surface of the current form.
/// Combinations the spec never produces (the window open in the popover
/// form, the popover shown in the window form) follow the same order.
public enum SurfaceToggleAction: Equatable, Sendable {
    case openPopover
    case closePopover
    case openWindow
    case raiseWindow
    case closeWindow

    /// `windowFrontmost` is ignored while the window is not open.
    public static func decide(
        form: SurfaceForm,
        popoverShown: Bool,
        windowOpen: Bool,
        windowFrontmost: Bool
    ) -> SurfaceToggleAction {
        if popoverShown { return .closePopover }
        if windowOpen { return windowFrontmost ? .closeWindow : .raiseWindow }
        switch form {
        case .popover: return .openPopover
        case .window: return .openWindow
        }
    }
}

/// "The window is frontmost" (§4.5 "tray icon click"): all four conditions
/// hold. Any one failing (another app is active, another window of the app
/// such as Settings is key, the window is minimized, or it is on another
/// Space) makes it not frontmost; a pinned window drawn above other apps is
/// not frontmost while it is not key. The values are read just before the
/// click or the hotkey press acts on them.
public enum WindowFrontmost {
    public static func isFrontmost(
        appActive: Bool,
        windowKey: Bool,
        windowMiniaturized: Bool,
        windowOnActiveSpace: Bool
    ) -> Bool {
        appActive && windowKey && !windowMiniaturized && windowOnActiveSpace
    }
}
