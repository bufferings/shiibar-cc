import XCTest

@testable import ShiibarCcCore

/// The Global shortcut field and its registration (M45 T1 / T2; DESIGN.md
/// §4.5 "global hotkey" / "Settings window" > General > Global shortcut), and
/// the hotkey's surface branch (§4.5 "tray icon click").
final class GlobalShortcutRecorderTests: XCTestCase {
    private let cmdShiftK = GlobalShortcut(keyCode: 0x28, modifiers: [.shift, .command], keyName: "K")
    private let ctrlOptSpace = GlobalShortcut(keyCode: 0x31, modifiers: [.control, .option], keyName: "Space")

    private func registered(_ shortcut: GlobalShortcut) -> GlobalShortcutRecorder {
        var recorder = GlobalShortcutRecorder()
        recorder.handle(.launched(stored: shortcut))
        recorder.handle(.registrationFinished(succeeded: true))
        XCTAssertEqual(recorder.registered, shortcut)
        return recorder
    }

    private func press(_ shortcut: GlobalShortcut) -> GlobalShortcutRecorderEvent {
        .keyPressed(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, keyName: shortcut.keyName)
    }

    // MARK: - Launch

    func testInitiallyUnregistered() {
        let recorder = GlobalShortcutRecorder()
        XCTAssertNil(recorder.registered)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.fieldText, "Record Shortcut")
        XCTAssertFalse(recorder.showsClearButton)
        XCTAssertNil(recorder.hint)
    }

    func testLaunchWithoutStoredValueRegistersNothing() {
        var recorder = GlobalShortcutRecorder()
        XCTAssertEqual(recorder.handle(.launched(stored: nil)), [])
        XCTAssertNil(recorder.registered)
    }

    func testLaunchRegistersTheStoredValue() {
        var recorder = GlobalShortcutRecorder()
        XCTAssertEqual(recorder.handle(.launched(stored: cmdShiftK)), [.register(cmdShiftK)])
        XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: true)), [])
        XCTAssertEqual(recorder.registered, cmdShiftK)
        XCTAssertEqual(recorder.fieldText, "\u{21E7}\u{2318}K")
        XCTAssertTrue(recorder.showsClearButton)
    }

    /// M45 T1: a failed launch registration keeps the stored value (no
    /// persist effect) and runs unregistered.
    func testLaunchRegistrationFailureRunsUnregisteredKeepingTheStoredValue() {
        var recorder = GlobalShortcutRecorder()
        recorder.handle(.launched(stored: cmdShiftK))
        XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: false)), [])
        XCTAssertNil(recorder.registered)
        XCTAssertNil(recorder.hint)
        XCTAssertEqual(recorder.fieldText, "Record Shortcut")
    }

    // MARK: - Recording

    func testRecordingFromUnregistered() {
        var recorder = GlobalShortcutRecorder()
        XCTAssertEqual(recorder.handle(.fieldClicked), [], "nothing registered: nothing to suspend")
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.fieldText, "Type shortcut")
        XCTAssertEqual(recorder.handle(press(ctrlOptSpace)), [.register(ctrlOptSpace)])
        XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: true)), [.persist(ctrlOptSpace)])
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.registered, ctrlOptSpace)
        XCTAssertEqual(recorder.fieldText, "\u{2303}\u{2325}Space")
    }

    /// §4.5: recording suspends the registration; a new combination replaces it.
    func testRecordingSuspendsAndReplacesTheRegistration() {
        var recorder = registered(cmdShiftK)
        XCTAssertEqual(recorder.handle(.fieldClicked), [.unregister])
        XCTAssertTrue(recorder.isRecording)
        XCTAssertFalse(recorder.showsClearButton)
        XCTAssertEqual(recorder.handle(press(ctrlOptSpace)), [.register(ctrlOptSpace)])
        XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: true)), [.persist(ctrlOptSpace)])
        XCTAssertEqual(recorder.registered, ctrlOptSpace)
    }

    /// Recording the combination already registered works (it was suspended).
    func testRecordingTheSameCombinationAgain() {
        var recorder = registered(cmdShiftK)
        recorder.handle(.fieldClicked)
        XCTAssertEqual(recorder.handle(press(cmdShiftK)), [.register(cmdShiftK)])
        XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: true)), [.persist(cmdShiftK)])
        XCTAssertEqual(recorder.registered, cmdShiftK)
    }

    /// §4.5: a combination without ⌃ / ⌥ / ⌘ (other than a function key)
    /// keeps recording and shows the hint; nothing is registered.
    func testInvalidCombinationKeepsRecordingWithTheHint() {
        for modifiers in [ShortcutModifiers(), [.shift]] {
            var recorder = registered(cmdShiftK)
            recorder.handle(.fieldClicked)
            XCTAssertEqual(recorder.handle(.keyPressed(keyCode: 0x28, modifiers: modifiers, keyName: "K")), [])
            XCTAssertTrue(recorder.isRecording)
            XCTAssertEqual(recorder.hint, .addModifier)
            XCTAssertEqual(recorder.fieldText, "Type shortcut")
            // A valid combination afterwards registers and clears the hint.
            XCTAssertEqual(recorder.handle(press(ctrlOptSpace)), [.register(ctrlOptSpace)])
            recorder.handle(.registrationFinished(succeeded: true))
            XCTAssertNil(recorder.hint)
            XCTAssertEqual(recorder.registered, ctrlOptSpace)
        }
    }

    func testFunctionKeyAloneRecords() {
        let f19 = GlobalShortcut(keyCode: 0x50, modifiers: [], keyName: "F19")
        var recorder = GlobalShortcutRecorder()
        recorder.handle(.fieldClicked)
        XCTAssertEqual(recorder.handle(press(f19)), [.register(f19)])
        XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: true)), [.persist(f19)])
        XCTAssertEqual(recorder.fieldText, "F19")
    }

    /// Keys without a usable name are not recorded; recording continues.
    func testUnnamedKeyIsIgnored() {
        var recorder = GlobalShortcutRecorder()
        recorder.handle(.fieldClicked)
        XCTAssertEqual(recorder.handle(.keyPressed(keyCode: 0x3F, modifiers: [.command], keyName: nil)), [])
        XCTAssertTrue(recorder.isRecording)
        XCTAssertNil(recorder.hint)
    }

    /// §4.5: the system refused it — the previous registration stays (it is
    /// put back) and the hint shows.
    func testRefusedRegistrationKeepsThePreviousOne() {
        var recorder = registered(cmdShiftK)
        recorder.handle(.fieldClicked)
        recorder.handle(press(ctrlOptSpace))
        XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: false)), [.register(cmdShiftK)])
        XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: true)), [])
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.registered, cmdShiftK)
        XCTAssertEqual(recorder.hint, .alreadyInUse)
        XCTAssertEqual(recorder.fieldText, "\u{21E7}\u{2318}K")
        // The next recording clears the hint.
        recorder.handle(.fieldClicked)
        XCTAssertNil(recorder.hint)
    }

    func testRefusedRegistrationWithNothingBefore() {
        var recorder = GlobalShortcutRecorder()
        recorder.handle(.fieldClicked)
        recorder.handle(press(ctrlOptSpace))
        XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: false)), [])
        XCTAssertNil(recorder.registered)
        XCTAssertEqual(recorder.hint, .alreadyInUse)
        XCTAssertEqual(recorder.fieldText, "Record Shortcut")
    }

    /// If putting the previous registration back also fails, nothing is
    /// registered.
    func testFailedRestoreLeavesNothingRegistered() {
        var recorder = registered(cmdShiftK)
        recorder.handle(.fieldClicked)
        recorder.handle(press(ctrlOptSpace))
        recorder.handle(.registrationFinished(succeeded: false))
        recorder.handle(.registrationFinished(succeeded: false))
        XCTAssertNil(recorder.registered)
        XCTAssertFalse(recorder.showsClearButton)
    }

    /// §4.5: Esc and a click outside the field cancel recording and keep
    /// the previous registration.
    func testCancelRestoresThePreviousRegistration() {
        let cancels: [(String, GlobalShortcutRecorderEvent)] = [
            ("Esc", .keyPressed(keyCode: ShortcutKeys.escape, modifiers: [], keyName: nil)),
            ("Esc with a modifier", .keyPressed(keyCode: ShortcutKeys.escape, modifiers: [.command], keyName: nil)),
            ("outside click", .recordingAbandoned),
        ]
        for (name, cancel) in cancels {
            var recorder = registered(cmdShiftK)
            recorder.handle(.fieldClicked)
            recorder.handle(.keyPressed(keyCode: 0x28, modifiers: [], keyName: "K"))
            XCTAssertEqual(recorder.hint, .addModifier, name)
            XCTAssertEqual(recorder.handle(cancel), [.register(cmdShiftK)], name)
            XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: true)), [], name)
            XCTAssertFalse(recorder.isRecording, name)
            XCTAssertNil(recorder.hint, name)
            XCTAssertEqual(recorder.registered, cmdShiftK, name)
        }
    }

    func testCancelWithNothingRegistered() {
        var recorder = GlobalShortcutRecorder()
        recorder.handle(.fieldClicked)
        XCTAssertEqual(recorder.handle(.recordingAbandoned), [])
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.registered)
    }

    func testEventsOutsideRecordingDoNothing() {
        var recorder = registered(cmdShiftK)
        XCTAssertEqual(recorder.handle(press(ctrlOptSpace)), [])
        XCTAssertEqual(recorder.handle(.recordingAbandoned), [])
        XCTAssertEqual(recorder.handle(.registrationFinished(succeeded: false)), [])
        XCTAssertEqual(recorder.registered, cmdShiftK)
        recorder.handle(.fieldClicked)
        XCTAssertEqual(recorder.handle(.fieldClicked), [], "a click on the recording field changes nothing")
        XCTAssertTrue(recorder.isRecording)
    }

    // MARK: - ×

    func testClearUnregistersAndRemovesTheStoredValue() {
        var recorder = registered(cmdShiftK)
        XCTAssertEqual(recorder.handle(.clearClicked), [.unregister, .persist(nil)])
        XCTAssertNil(recorder.registered)
        XCTAssertEqual(recorder.fieldText, "Record Shortcut")
        XCTAssertFalse(recorder.showsClearButton)
        XCTAssertEqual(recorder.handle(.clearClicked), [], "nothing to clear")
    }

    // MARK: - Surface branch (§4.5 "tray icon click" / "global hotkey")

    /// Every combination of form × popover shown × window open × window
    /// frontmost. The order: a shown popover closes; an open window closes
    /// when frontmost and comes forward otherwise; else the form's surface
    /// opens. Combinations the spec never produces follow the same order.
    func testSurfaceToggleCoversEveryCombination() {
        for form in [SurfaceForm.popover, .window] {
            for popoverShown in [false, true] {
                for windowOpen in [false, true] {
                    for frontmost in [false, true] {
                        let expected: SurfaceToggleAction
                        if popoverShown {
                            expected = .closePopover
                        } else if windowOpen {
                            expected = frontmost ? .closeWindow : .raiseWindow
                        } else {
                            expected = form == .popover ? .openPopover : .openWindow
                        }
                        XCTAssertEqual(
                            SurfaceToggleAction.decide(form: form, popoverShown: popoverShown,
                                                       windowOpen: windowOpen, windowFrontmost: frontmost),
                            expected,
                            "form \(form) popover \(popoverShown) window \(windowOpen) frontmost \(frontmost)")
                    }
                }
            }
        }
    }

    /// The §4.5 table and the popover form, spelled out.
    func testSurfaceToggleSpecRows() {
        // Popover form: the popover toggles.
        XCTAssertEqual(SurfaceToggleAction.decide(form: .popover, popoverShown: false, windowOpen: false, windowFrontmost: false), .openPopover)
        XCTAssertEqual(SurfaceToggleAction.decide(form: .popover, popoverShown: true, windowOpen: false, windowFrontmost: false), .closePopover)
        // Window form: closed -> open; open, not frontmost -> raise;
        // frontmost -> close.
        XCTAssertEqual(SurfaceToggleAction.decide(form: .window, popoverShown: false, windowOpen: false, windowFrontmost: false), .openWindow)
        XCTAssertEqual(SurfaceToggleAction.decide(form: .window, popoverShown: false, windowOpen: false, windowFrontmost: true), .openWindow,
                       "a closed window is never frontmost")
        XCTAssertEqual(SurfaceToggleAction.decide(form: .window, popoverShown: false, windowOpen: true, windowFrontmost: false), .raiseWindow)
        XCTAssertEqual(SurfaceToggleAction.decide(form: .window, popoverShown: false, windowOpen: true, windowFrontmost: true), .closeWindow)
        // Not produced by the spec: they follow the order.
        XCTAssertEqual(SurfaceToggleAction.decide(form: .popover, popoverShown: false, windowOpen: true, windowFrontmost: true), .closeWindow)
        XCTAssertEqual(SurfaceToggleAction.decide(form: .popover, popoverShown: false, windowOpen: true, windowFrontmost: false), .raiseWindow)
        XCTAssertEqual(SurfaceToggleAction.decide(form: .window, popoverShown: true, windowOpen: false, windowFrontmost: false), .closePopover)
        XCTAssertEqual(SurfaceToggleAction.decide(form: .window, popoverShown: true, windowOpen: true, windowFrontmost: true), .closePopover)
    }

    /// §4.5: frontmost only when all four conditions hold.
    func testWindowFrontmostNeedsAllFourConditions() {
        for active in [false, true] {
            for key in [false, true] {
                for miniaturized in [false, true] {
                    for onSpace in [false, true] {
                        XCTAssertEqual(
                            WindowFrontmost.isFrontmost(appActive: active, windowKey: key,
                                                        windowMiniaturized: miniaturized, windowOnActiveSpace: onSpace),
                            active && key && !miniaturized && onSpace,
                            "active \(active) key \(key) minimized \(miniaturized) on space \(onSpace)")
                    }
                }
            }
        }
    }
}
