import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The global hotkey's registration (M45 T1 / T2; DESIGN.md §4.5 "global
/// hotkey" / "Settings window" > General > Global shortcut) against a spy
/// registrar and in-memory defaults — no real hotkey is registered and
/// `UserDefaults.standard` is never used.
@MainActor
final class GlobalHotKeyModelTests: XCTestCase {
    private final class SpyRegistrar: GlobalHotKeyRegistering {
        var onPressed: () -> Void = {}
        /// Every call, in order: "register ⇧⌘K" / "unregister".
        var calls: [String] = []
        /// The combination the system currently holds.
        private(set) var current: GlobalShortcut?
        /// Combinations the "system" refuses.
        var refused: Set<GlobalShortcut> = []

        func register(_ shortcut: GlobalShortcut) -> Bool {
            calls.append("register \(shortcut.displayString)")
            current = nil
            guard !refused.contains(shortcut) else { return false }
            current = shortcut
            return true
        }

        func unregister() {
            calls.append("unregister")
            current = nil
        }
    }

    private let cmdShiftK = GlobalShortcut(keyCode: 0x28, modifiers: [.shift, .command], keyName: "K")
    private let ctrlOptSpace = GlobalShortcut(keyCode: 0x31, modifiers: [.control, .option], keyName: "Space")
    private var registrar = SpyRegistrar()
    private var defaults = InMemoryDefaults()

    override func setUp() {
        super.setUp()
        registrar = SpyRegistrar()
        defaults = InMemoryDefaults()
    }

    private func makeModel(stored: GlobalShortcut? = nil) -> GlobalHotKeyModel {
        if let stored {
            defaults.set(GlobalShortcutCodec.encode(stored), forKey: GlobalShortcutCodec.defaultsKey)
        }
        return GlobalHotKeyModel(registrar: registrar, defaults: defaults)
    }

    private var storedValue: GlobalShortcut? {
        GlobalShortcutCodec.decode(defaults.object(forKey: GlobalShortcutCodec.defaultsKey))
    }

    private func press(_ model: GlobalHotKeyModel, _ shortcut: GlobalShortcut) {
        model.keyPressed(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, keyName: shortcut.keyName)
    }

    // MARK: - Launch

    func testLaunchWithNothingStoredRegistersNothing() {
        let model = makeModel()
        model.start()
        XCTAssertEqual(registrar.calls, [])
        XCTAssertNil(model.recorder.registered)
    }

    func testLaunchRegistersTheStoredCombination() {
        let model = makeModel(stored: cmdShiftK)
        model.start()
        XCTAssertEqual(registrar.calls, ["register \u{21E7}\u{2318}K"])
        XCTAssertEqual(registrar.current, cmdShiftK)
        XCTAssertEqual(model.recorder.registered, cmdShiftK)
        model.start()
        XCTAssertEqual(registrar.calls.count, 1, "launch registers once")
    }

    /// M45 T1: a refused launch registration keeps the stored value and
    /// runs unregistered.
    func testLaunchRefusalKeepsTheStoredValue() {
        registrar.refused = [cmdShiftK]
        let model = makeModel(stored: cmdShiftK)
        model.start()
        XCTAssertNil(registrar.current)
        XCTAssertNil(model.recorder.registered)
        XCTAssertEqual(storedValue, cmdShiftK)
    }

    func testBrokenStoredValueRegistersNothing() {
        defaults.set("{broken", forKey: GlobalShortcutCodec.defaultsKey)
        let model = GlobalHotKeyModel(registrar: registrar, defaults: defaults)
        model.start()
        XCTAssertEqual(registrar.calls, [])
        XCTAssertNil(model.recorder.registered)
    }

    // MARK: - Recording

    /// §4.5: the registration is suspended while recording; a recorded
    /// combination is registered and stored at once.
    func testRecordingSuspendsThenRegistersAndStores() {
        let model = makeModel(stored: cmdShiftK)
        model.start()
        model.fieldClicked()
        XCTAssertNil(registrar.current, "suspended while recording")
        XCTAssertEqual(registrar.calls.last, "unregister")
        press(model, ctrlOptSpace)
        XCTAssertEqual(registrar.current, ctrlOptSpace)
        XCTAssertEqual(storedValue, ctrlOptSpace)
        XCTAssertFalse(model.recorder.isRecording)
    }

    /// M45 T2: ending or cancelling recording restores the registration.
    func testCancelRestoresTheRegistration() {
        let cancels: [(String, (GlobalHotKeyModel) -> Void)] = [
            ("Esc", { $0.keyPressed(keyCode: ShortcutKeys.escape, modifiers: [], keyName: nil) }),
            ("outside click", { $0.recordingAbandoned() }),
        ]
        for (name, cancel) in cancels {
            registrar = SpyRegistrar()
            defaults = InMemoryDefaults()
            let model = makeModel(stored: cmdShiftK)
            model.start()
            model.fieldClicked()
            XCTAssertNil(registrar.current, name)
            cancel(model)
            XCTAssertEqual(registrar.current, cmdShiftK, name)
            XCTAssertEqual(storedValue, cmdShiftK, name)
            XCTAssertFalse(model.recorder.isRecording, name)
        }
    }

    /// §4.5: an invalid combination keeps recording (still suspended) and
    /// registers nothing.
    func testInvalidCombinationStaysSuspended() {
        let model = makeModel(stored: cmdShiftK)
        model.start()
        model.fieldClicked()
        let callsBefore = registrar.calls
        model.keyPressed(keyCode: 0x28, modifiers: [.shift], keyName: "K")
        XCTAssertEqual(registrar.calls, callsBefore)
        XCTAssertNil(registrar.current)
        XCTAssertEqual(model.recorder.hint, .addModifier)
        XCTAssertTrue(model.recorder.isRecording)
    }

    /// §4.5: a refused combination keeps the previous registration (put
    /// back with the system) and the stored value.
    func testRefusalKeepsThePreviousRegistration() {
        registrar.refused = [ctrlOptSpace]
        let model = makeModel(stored: cmdShiftK)
        model.start()
        model.fieldClicked()
        press(model, ctrlOptSpace)
        XCTAssertEqual(registrar.calls, [
            "register \u{21E7}\u{2318}K",
            "unregister",
            "register \u{2303}\u{2325}Space",
            "register \u{21E7}\u{2318}K",
        ])
        XCTAssertEqual(registrar.current, cmdShiftK)
        XCTAssertEqual(model.recorder.registered, cmdShiftK)
        XCTAssertEqual(model.recorder.hint, .alreadyInUse)
        XCTAssertEqual(storedValue, cmdShiftK)
    }

    // MARK: - ×

    func testClearUnregistersAndRemovesTheStoredValue() {
        let model = makeModel(stored: cmdShiftK)
        model.start()
        model.clearClicked()
        XCTAssertEqual(registrar.calls.last, "unregister")
        XCTAssertNil(registrar.current)
        XCTAssertNil(defaults.object(forKey: GlobalShortcutCodec.defaultsKey))
        XCTAssertEqual(model.recorder.fieldText, "Record Shortcut")
    }

    // MARK: - Presses

    func testPressReachesTheHandler() {
        let model = makeModel(stored: cmdShiftK)
        var presses = 0
        model.onPressed = { presses += 1 }
        model.start()
        registrar.onPressed()
        XCTAssertEqual(presses, 1)
    }

    /// The Carbon modifier bits (HIToolbox `Events.h`: cmdKey 1<<8,
    /// shiftKey 1<<9, optionKey 1<<11, controlKey 1<<12).
    func testCarbonModifierBits() {
        XCTAssertEqual(CarbonHotKeyRegistrar.carbonModifiers([]), 0)
        XCTAssertEqual(CarbonHotKeyRegistrar.carbonModifiers([.command]), 1 << 8)
        XCTAssertEqual(CarbonHotKeyRegistrar.carbonModifiers([.shift]), 1 << 9)
        XCTAssertEqual(CarbonHotKeyRegistrar.carbonModifiers([.option]), 1 << 11)
        XCTAssertEqual(CarbonHotKeyRegistrar.carbonModifiers([.control]), 1 << 12)
        XCTAssertEqual(CarbonHotKeyRegistrar.carbonModifiers([.control, .option, .shift, .command]), 0x1B00)
    }

    func testEventModifiers() {
        XCTAssertEqual(GlobalHotKeyModel.modifiers(of: [.command, .shift, .capsLock, .function]), [.command, .shift])
        XCTAssertEqual(GlobalHotKeyModel.modifiers(of: [.control, .option]), [.control, .option])
    }
}
