// The global hotkey's key combination (DESIGN.md §4.5 "global hotkey" and
// "Settings window" > General > Global shortcut, §8.50): which combinations
// can be registered, how a combination is shown, and how it is stored in
// UserDefaults. The Carbon registration itself and the key capture live in
// the app target; this file is Foundation-only.

import Foundation

/// The modifier keys of a shortcut (§4.5: any combination of ⌃ / ⌥ / ⇧ / ⌘).
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// Every modifier this type knows; other bits are not part of a shortcut.
    public static let all: ShortcutModifiers = [.control, .option, .shift, .command]

    /// The modifier symbols in display order ⌃ ⌥ ⇧ ⌘ (the system's order).
    public var symbols: String {
        var result = ""
        if contains(.control) { result += "\u{2303}" }
        if contains(.option) { result += "\u{2325}" }
        if contains(.shift) { result += "\u{21E7}" }
        if contains(.command) { result += "\u{2318}" }
        return result
    }
}

/// A recorded key combination: the virtual key code (`kVK_*`, layout
/// independent — what the system matches), the modifiers, and the key's name
/// as the keyboard layout produced it when it was recorded (§4.5: the name is
/// stored and shown as recorded).
public struct GlobalShortcut: Equatable, Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: ShortcutModifiers
    public let keyName: String

    public init(keyCode: UInt16, modifiers: ShortcutModifiers, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
        self.keyName = keyName
    }

    /// The modifier symbols then the key name, e.g. `⌃⌥Space`, `⇧⌘K` (§4.5).
    public var displayString: String { modifiers.symbols + keyName }

    /// Whether the system may register this combination (§4.5).
    public var validation: GlobalShortcutValidation {
        GlobalShortcutValidation.validate(keyCode: keyCode, modifiers: modifiers)
    }
}

/// §4.5: any modifiers may be used, but a combination without ⌃ / ⌥ / ⌘ (no
/// modifier, or ⇧ only) is allowed only on a function key (F1-F20) — such a
/// combination on any other key would stop that key's typing in every app.
public enum GlobalShortcutValidation: Equatable, Sendable {
    case valid
    /// Shown as `GlobalShortcutHint.addModifier`; recording continues.
    case needsModifier

    public static func validate(keyCode: UInt16, modifiers: ShortcutModifiers) -> GlobalShortcutValidation {
        if !modifiers.intersection([.control, .option, .command]).isEmpty { return .valid }
        return ShortcutKeys.isFunctionKey(keyCode) ? .valid : .needsModifier
    }
}

/// The line under the field (§4.5 Settings > General > Global shortcut).
public enum GlobalShortcutHint: Equatable, Sendable {
    /// A combination that cannot be registered was pressed.
    case addModifier
    /// The system refused the registration.
    case alreadyInUse

    public var text: String {
        switch self {
        case .addModifier: return "Add \u{2303}, \u{2325}, or \u{2318} to the shortcut"
        case .alreadyInUse: return "This shortcut is already in use"
        }
    }
}

/// Virtual key codes (`kVK_*` in HIToolbox `Events.h`) and key names.
public enum ShortcutKeys {
    public static let escape: UInt16 = 0x35

    /// F1-F20, in order (`kVK_F1` ... `kVK_F20`).
    public static let functionKeys: [UInt16] = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys.contains(keyCode)
    }

    /// Keys whose name is not a typed character. Assumption: the spec names
    /// only `Space` (§4.5 example `⌃⌥Space`) and F1-F20; the other names are
    /// the symbols macOS menus use for these keys.
    private static let fixedNames: [UInt16: String] = {
        var names: [UInt16: String] = [
            0x31: "Space",
            0x24: "\u{21A9}",  // Return
            0x4C: "\u{2324}",  // keypad Enter
            0x30: "\u{21E5}",  // Tab
            0x33: "\u{232B}",  // Delete
            0x75: "\u{2326}",  // Forward Delete
            0x7B: "\u{2190}",  // Left Arrow
            0x7C: "\u{2192}",  // Right Arrow
            0x7E: "\u{2191}",  // Up Arrow
            0x7D: "\u{2193}",  // Down Arrow
            0x73: "\u{2196}",  // Home
            0x77: "\u{2198}",  // End
            0x74: "\u{21DE}",  // Page Up
            0x79: "\u{21DF}",  // Page Down
            0x47: "\u{2327}",  // keypad Clear
        ]
        for (index, code) in functionKeys.enumerated() {
            names[code] = "F\(index + 1)"
        }
        return names
    }()

    /// The name to store for a pressed key: a fixed name for the keys above,
    /// otherwise the character the current keyboard layout types for the key
    /// without modifiers (`characters`), uppercased. nil when the key has no
    /// usable name (no character, or a control character) — such a key is
    /// not recorded.
    public static func keyName(keyCode: UInt16, characters: String?) -> String? {
        if let fixed = fixedNames[keyCode] { return fixed }
        guard let characters else { return nil }
        let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              // Private-use code points are AppKit's function-key characters.
              !trimmed.unicodeScalars.contains(where: { (0xE000...0xF8FF).contains($0.value) })
        else { return nil }
        return trimmed.uppercased()
    }
}

/// The UserDefaults format of the shortcut: a JSON string
/// `{"keyCode":40,"modifiers":["command","shift"],"keyName":"K"}`. No value
/// = unregistered (§4.5: the initial state). A value that does not decode, or
/// decodes to a combination that cannot be registered, reads as unregistered.
public enum GlobalShortcutCodec {
    public static let defaultsKey = "cc.shiibar.globalShortcut"

    private struct Stored: Codable {
        let keyCode: UInt16
        let modifiers: [String]
        let keyName: String
    }

    private static let modifierNames: [(ShortcutModifiers, String)] = [
        (.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command"),
    ]

    public static func encode(_ shortcut: GlobalShortcut) -> String {
        let stored = Stored(
            keyCode: shortcut.keyCode,
            modifiers: modifierNames.filter { shortcut.modifiers.contains($0.0) }.map(\.1),
            keyName: shortcut.keyName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a struct of plain fields cannot fail.
        let data = (try? encoder.encode(stored)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `raw` is the UserDefaults object as read (any type).
    public static func decode(_ raw: Any?) -> GlobalShortcut? {
        guard let string = raw as? String,
              let stored = try? JSONDecoder().decode(Stored.self, from: Data(string.utf8)),
              !stored.keyName.isEmpty
        else { return nil }
        var modifiers: ShortcutModifiers = []
        for name in stored.modifiers {
            guard let modifier = modifierNames.first(where: { $0.1 == name })?.0 else { return nil }
            modifiers.insert(modifier)
        }
        let shortcut = GlobalShortcut(keyCode: stored.keyCode, modifiers: modifiers, keyName: stored.keyName)
        guard shortcut.validation == .valid else { return nil }
        return shortcut
    }
}
