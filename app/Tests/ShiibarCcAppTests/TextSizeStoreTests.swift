import XCTest
import ShiibarCcCore
@testable import ShiibarCcApp

/// The text size store and the Settings window's Text size field (DESIGN.md
/// §4.5 "text size" / "Settings window"). In-memory defaults only: nothing
/// reaches `UserDefaults.standard`.
@MainActor
final class TextSizeStoreTests: XCTestCase {
    private var defaults = InMemoryDefaults()

    override func setUp() {
        super.setUp()
        defaults = InMemoryDefaults()
    }

    private var stored: Any? { defaults.object(forKey: TextSizeStore.defaultsKey) }

    // MARK: - Loading and saving

    func testKeyKeepsItsName() {
        XCTAssertEqual(TextSizeStore.defaultsKey, "cc.shiibar.conversationsTextSize")
    }

    func testLoadingInterpretsTheStoredValueWithoutRewritingIt() {
        let cases: [(String, Any?, Int)] = [
            ("missing", nil, 13),
            ("integer", 15, 15),
            ("double saved before", 16.0, 16),
            ("fraction", 14.6, 15),
            ("19 saved before", 19.0, 18),
            ("20 saved before", 20.0, 18),
            ("below the range", 8, 9),
        ]
        for (name, value, points) in cases {
            defaults = InMemoryDefaults()
            if let value { defaults.set(value, forKey: TextSizeStore.defaultsKey) }
            let store = TextSizeStore(defaults: defaults)
            XCTAssertEqual(store.size.points, points, name)
            if let double = value as? Double {
                XCTAssertEqual(stored as? Double, double, "\(name): reading alone never rewrites")
            } else if let int = value as? Int {
                XCTAssertEqual(stored as? Int, int, "\(name): reading alone never rewrites")
            } else {
                XCTAssertNil(stored, "\(name): reading alone never writes")
            }
        }
    }

    func testApplySavesAWholeNumberAndReloads() {
        let store = TextSizeStore(defaults: defaults)
        XCTAssertTrue(store.apply(TextSize(clamping: 17)))
        XCTAssertEqual(stored as? Int, 17)
        XCTAssertEqual(TextSizeStore(defaults: defaults).size.points, 17)
        XCTAssertFalse(store.apply(TextSize(clamping: 17)), "the same value changes nothing")
    }

    func testStepsStopAtTheEnds() {
        defaults.set(18, forKey: TextSizeStore.defaultsKey)
        let store = TextSizeStore(defaults: defaults)
        store.increase()
        XCTAssertEqual(store.size.points, 18)
        store.decrease()
        XCTAssertEqual(store.size.points, 17)
        store.reset()
        XCTAssertEqual(store.size.points, 13)
        for _ in 0..<10 { store.decrease() }
        XCTAssertEqual(store.size.points, 9)
        XCTAssertEqual(stored as? Int, 9)
    }

    // MARK: - Settings field

    private func field(_ store: TextSizeStore) -> TextSizeFieldModel {
        TextSizeFieldModel(store: store)
    }

    func testValidEntryApplies() {
        let store = TextSizeStore(defaults: defaults)
        let field = field(store)
        XCTAssertEqual(field.text, "13")
        field.text = " 16 "
        field.commit()
        XCTAssertEqual(store.size.points, 16)
        XCTAssertEqual(stored as? Int, 16)
        XCTAssertEqual(field.text, "16")
        XCTAssertNil(field.error)
    }

    func testInvalidEntriesShowTheErrorAndRevertToTheCurrentValue() {
        let cases: [(String, TextSize.InputError)] = [
            ("abc", .notWholeNumber),
            ("", .notWholeNumber),
            ("  ", .notWholeNumber),
            ("12.5", .notWholeNumber),
            ("19", .outOfRange),
            ("8", .outOfRange),
        ]
        for (text, error) in cases {
            defaults = InMemoryDefaults()
            defaults.set(15, forKey: TextSizeStore.defaultsKey)
            let store = TextSizeStore(defaults: defaults)
            let field = field(store)
            field.text = text
            field.commit()
            XCTAssertEqual(field.error, error, "\"\(text)\"")
            XCTAssertEqual(field.text, "15", "\"\(text)\": the field shows the current value again")
            XCTAssertEqual(store.size.points, 15, "\"\(text)\"")
            XCTAssertEqual(stored as? Int, 15, "\"\(text)\": nothing is saved")
        }
        XCTAssertEqual(TextSize.InputError.notWholeNumber.message, "Enter a whole number")
        XCTAssertEqual(TextSize.InputError.outOfRange.message, "Enter a number from 9 to 18")
    }

    func testSameValueClearsTheErrorWithoutSaving() {
        let store = TextSizeStore(defaults: defaults)
        let field = field(store)
        field.text = "abc"
        field.commit()
        XCTAssertEqual(field.error, .notWholeNumber)
        field.text = "13"
        field.commit()
        XCTAssertNil(field.error, "confirming the current value is applying a value")
        XCTAssertNil(stored, "the same value is not saved")
    }

    func testFocusLossAppliesOnlyAnEditedField() {
        let store = TextSizeStore(defaults: defaults)
        let field = field(store)
        field.text = "19"
        field.commit()
        XCTAssertEqual(field.error, .outOfRange)
        field.commitIfEdited()
        XCTAssertEqual(field.error, .outOfRange, "leaving the reverted field applies nothing")
        field.text = "12"
        field.commitIfEdited()
        XCTAssertEqual(store.size.points, 12)
        XCTAssertNil(field.error)
    }

    func testDiscardedEditAppliesNothing() {
        let store = TextSizeStore(defaults: defaults)
        let field = field(store)
        field.text = "17"
        field.discardEdit()
        XCTAssertEqual(field.text, "13")
        XCTAssertEqual(store.size.points, 13)
        XCTAssertNil(stored)
    }

    func testStepperStepsByOneAndDoesNothingAtTheEnds() {
        defaults.set(17, forKey: TextSizeStore.defaultsKey)
        let store = TextSizeStore(defaults: defaults)
        let field = field(store)
        field.stepUp()
        XCTAssertEqual(store.size.points, 18)
        XCTAssertEqual(field.text, "18")
        field.stepUp()
        XCTAssertEqual(store.size.points, 18)
        field.stepDown()
        XCTAssertEqual(field.text, "17")

        defaults = InMemoryDefaults()
        defaults.set(9, forKey: TextSizeStore.defaultsKey)
        let low = TextSizeStore(defaults: defaults)
        let lowField = self.field(low)
        lowField.stepDown()
        XCTAssertEqual(low.size.points, 9)
        XCTAssertEqual(stored as? Int, 9)
        XCTAssertEqual(lowField.text, "9")
    }

    func testStepperAndKeysClearTheErrorAndUpdateTheField() {
        let store = TextSizeStore(defaults: defaults)
        let field = field(store)
        field.text = "abc"
        field.commit()
        field.stepUp()
        XCTAssertNil(field.error, "the stepper applies a value")
        XCTAssertEqual(field.text, "14")

        field.text = "30"
        field.commit()
        XCTAssertEqual(field.error, .outOfRange)
        // ⌘= in the popover or the window goes through the same store.
        store.increase()
        XCTAssertEqual(field.text, "15", "a key change shows in the field")
        XCTAssertNil(field.error)
        store.reset()
        XCTAssertEqual(field.text, "13")
    }
}
