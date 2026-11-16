import XCTest

@testable import ShiibarCcCore

/// The global hotkey's combination (M45 T2; DESIGN.md §4.5 "Settings window"
/// > General > Global shortcut): which combinations can be registered, the
/// display string, and the UserDefaults format.
final class GlobalShortcutTests: XCTestCase {
    private let keyK: UInt16 = 0x28
    private let space: UInt16 = 0x31
    private let f5: UInt16 = 0x60
    private let f19: UInt16 = 0x50

    // MARK: - Validation

    /// §4.5: any modifiers; without ⌃ / ⌥ / ⌘ only a function key.
    func testValidation() {
        struct Case {
            let name: String
            let keyCode: UInt16
            let modifiers: ShortcutModifiers
            let expected: GlobalShortcutValidation
        }
        let cases = [
            Case(name: "no modifier, letter", keyCode: keyK, modifiers: [], expected: .needsModifier),
            Case(name: "no modifier, Space", keyCode: space, modifiers: [], expected: .needsModifier),
            Case(name: "shift only, letter", keyCode: keyK, modifiers: [.shift], expected: .needsModifier),
            Case(name: "shift only, Space", keyCode: space, modifiers: [.shift], expected: .needsModifier),
            Case(name: "control", keyCode: keyK, modifiers: [.control], expected: .valid),
            Case(name: "option", keyCode: keyK, modifiers: [.option], expected: .valid),
            Case(name: "command", keyCode: keyK, modifiers: [.command], expected: .valid),
            Case(name: "shift + command", keyCode: keyK, modifiers: [.shift, .command], expected: .valid),
            Case(name: "shift + control", keyCode: space, modifiers: [.shift, .control], expected: .valid),
            Case(name: "shift + option", keyCode: space, modifiers: [.shift, .option], expected: .valid),
            Case(name: "all four", keyCode: keyK, modifiers: [.control, .option, .shift, .command], expected: .valid),
            Case(name: "function key alone", keyCode: f5, modifiers: [], expected: .valid),
            Case(name: "function key with shift", keyCode: f19, modifiers: [.shift], expected: .valid),
            Case(name: "function key with command", keyCode: f19, modifiers: [.command], expected: .valid),
        ]
        for testCase in cases {
            XCTAssertEqual(
                GlobalShortcutValidation.validate(keyCode: testCase.keyCode, modifiers: testCase.modifiers),
                testCase.expected, testCase.name)
        }
    }

    /// F1-F20 are the function keys (`kVK_F1` ... `kVK_F20`); nothing else is.
    func testFunctionKeysAreF1ThroughF20() {
        XCTAssertEqual(ShortcutKeys.functionKeys.count, 20)
        XCTAssertEqual(Set(ShortcutKeys.functionKeys).count, 20)
        let names = ShortcutKeys.functionKeys.map { ShortcutKeys.keyName(keyCode: $0, characters: nil) }
        XCTAssertEqual(names, (1...20).map { "F\($0)" })
        for keyCode in [keyK, space, UInt16(0x24), UInt16(0x7E), UInt16(0x35)] {
            XCTAssertFalse(ShortcutKeys.isFunctionKey(keyCode), "\(keyCode)")
        }
    }

    // MARK: - Display

    /// §4.5: modifier symbols in the order ⌃ ⌥ ⇧ ⌘, then the key name.
    func testDisplayStringOrdersModifiers() {
        XCTAssertEqual(
            GlobalShortcut(keyCode: space, modifiers: [.option, .control], keyName: "Space").displayString,
            "\u{2303}\u{2325}Space")
        XCTAssertEqual(
            GlobalShortcut(keyCode: keyK, modifiers: [.command, .shift], keyName: "K").displayString,
            "\u{21E7}\u{2318}K")
        XCTAssertEqual(
            GlobalShortcut(keyCode: keyK, modifiers: [.command, .shift, .option, .control], keyName: "K").displayString,
            "\u{2303}\u{2325}\u{21E7}\u{2318}K")
        XCTAssertEqual(GlobalShortcut(keyCode: f5, modifiers: [], keyName: "F5").displayString, "F5")
    }

    /// §4.5: the key name is the layout's character as recorded (uppercased);
    /// Space and the function keys have fixed names.
    func testKeyNames() {
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: keyK, characters: "k"), "K")
        // A non-US layout: the character the layout types for that key.
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: 0x10, characters: "z"), "Z")
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: 0x1B, characters: "-"), "-")
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: space, characters: " "), "Space")
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: f5, characters: "\u{F708}"), "F5")
        XCTAssertNil(ShortcutKeys.keyName(keyCode: 0x3F, characters: ""), "no character")
        XCTAssertNil(ShortcutKeys.keyName(keyCode: 0x3F, characters: nil), "no character")
        XCTAssertNil(ShortcutKeys.keyName(keyCode: 0x6E, characters: "\u{10}"), "control character")
        XCTAssertNil(ShortcutKeys.keyName(keyCode: 0x72, characters: "\u{F746}"), "AppKit function-key character")
    }

    func testHintTexts() {
        XCTAssertEqual(GlobalShortcutHint.addModifier.text, "Add \u{2303}, \u{2325}, or \u{2318} to the shortcut")
        XCTAssertEqual(GlobalShortcutHint.alreadyInUse.text, "This shortcut is already in use")
    }

    // MARK: - Stored format

    func testCodecRoundTrip() {
        let shortcuts = [
            GlobalShortcut(keyCode: space, modifiers: [.control, .option], keyName: "Space"),
            GlobalShortcut(keyCode: keyK, modifiers: [.shift, .command], keyName: "K"),
            GlobalShortcut(keyCode: keyK, modifiers: [.control, .option, .shift, .command], keyName: "K"),
            GlobalShortcut(keyCode: f19, modifiers: [], keyName: "F19"),
            GlobalShortcut(keyCode: f5, modifiers: [.shift], keyName: "F5"),
            GlobalShortcut(keyCode: 0x2B, modifiers: [.command], keyName: ","),
        ]
        for shortcut in shortcuts {
            let encoded = GlobalShortcutCodec.encode(shortcut)
            XCTAssertEqual(GlobalShortcutCodec.decode(encoded), shortcut, encoded)
        }
    }

    func testCodecFormat() {
        let encoded = GlobalShortcutCodec.encode(GlobalShortcut(keyCode: keyK, modifiers: [.command, .shift], keyName: "K"))
        XCTAssertEqual(encoded, #"{"keyCode":40,"keyName":"K","modifiers":["shift","command"]}"#)
        XCTAssertEqual(GlobalShortcutCodec.defaultsKey, "cc.shiibar.globalShortcut")
    }

    /// A stored value that does not decode — or decodes to a combination
    /// that cannot be registered — reads as unregistered.
    func testBrokenStoredValuesReadAsUnregistered() {
        let broken: [Any?] = [
            nil,
            "",
            "not json",
            42,
            ["keyCode": 40],
            #"{"keyCode":40,"modifiers":["command"]}"#,
            #"{"keyCode":40,"modifiers":["hyper"],"keyName":"K"}"#,
            #"{"keyCode":-1,"modifiers":["command"],"keyName":"K"}"#,
            #"{"keyCode":40,"modifiers":["command"],"keyName":""}"#,
            #"{"keyCode":40,"modifiers":[],"keyName":"K"}"#,
            #"{"keyCode":40,"modifiers":["shift"],"keyName":"K"}"#,
        ]
        for value in broken {
            XCTAssertNil(GlobalShortcutCodec.decode(value), String(describing: value))
        }
    }
}
