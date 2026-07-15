import XCTest
@testable import ShiibarCcCore

/// The ⟳ rotation discipline (DESIGN.md §4.6/§9/§8.44): phase anchored to the
/// refresh start (always upright at 0°), 0.6s per turn, and a stop that lands
/// only on whole-turn boundaries with a one-turn minimum.
final class ConversationsRefreshSpinTests: XCTestCase {
    private let period = ConversationsRefreshSpin.periodSeconds

    func testPeriodMatchesSpec() {
        // §9: 0.6 seconds per turn.
        XCTAssertEqual(ConversationsRefreshSpin.periodSeconds, 0.6)
    }

    func testStartsUpright() {
        // §8.44: the phase is start-anchored, so elapsed 0 is exactly upright.
        XCTAssertEqual(ConversationsRefreshSpin.angleDegrees(elapsedSeconds: 0), 0, accuracy: 1e-9)
    }

    func testAngleAdvancesOneTurnPerPeriod() {
        // Quarter, half, three-quarter of a 0.6s turn.
        XCTAssertEqual(ConversationsRefreshSpin.angleDegrees(elapsedSeconds: period / 4), 90, accuracy: 1e-9)
        XCTAssertEqual(ConversationsRefreshSpin.angleDegrees(elapsedSeconds: period / 2), 180, accuracy: 1e-9)
        XCTAssertEqual(ConversationsRefreshSpin.angleDegrees(elapsedSeconds: period * 3 / 4), 270, accuracy: 1e-9)
    }

    func testAngleIsZeroAtEveryWholeTurnBoundary() {
        // §8.44: whole-turn boundaries are angle zero, so the switch to the
        // static glyph never jumps.
        for turn in 1...5 {
            let angle = ConversationsRefreshSpin.angleDegrees(elapsedSeconds: period * Double(turn))
            XCTAssertEqual(angle.truncatingRemainder(dividingBy: 360), 0, accuracy: 1e-6)
        }
    }

    func testStopMinimumIsOneWholeTurnWhenRunEndsEarly() {
        // §9/§8.43: a run that finishes in tens of milliseconds still spins a
        // full turn.
        XCTAssertEqual(ConversationsRefreshSpin.stopElapsedSeconds(runEndSeconds: 0), period, accuracy: 1e-9)
        XCTAssertEqual(ConversationsRefreshSpin.stopElapsedSeconds(runEndSeconds: 0.03), period, accuracy: 1e-9)
        XCTAssertEqual(ConversationsRefreshSpin.stopElapsedSeconds(runEndSeconds: period), period, accuracy: 1e-9)
    }

    func testStopRoundsUpToNextWholeTurnWhenRunOverruns() {
        // A run ending just past one turn keeps spinning to two turns; just
        // past two turns to three.
        XCTAssertEqual(ConversationsRefreshSpin.stopElapsedSeconds(runEndSeconds: period + 0.01), period * 2, accuracy: 1e-9)
        XCTAssertEqual(ConversationsRefreshSpin.stopElapsedSeconds(runEndSeconds: period * 2 + 0.01), period * 3, accuracy: 1e-9)
    }

    func testStopStaysOnBoundaryWhenRunEndsExactlyOnIt() {
        // A run ending exactly on a whole-turn boundary stops there (float
        // error must not add an extra turn).
        XCTAssertEqual(ConversationsRefreshSpin.stopElapsedSeconds(runEndSeconds: period * 2), period * 2, accuracy: 1e-9)
        XCTAssertEqual(ConversationsRefreshSpin.stopElapsedSeconds(runEndSeconds: period * 3), period * 3, accuracy: 1e-9)
    }

    func testStopLandsOnAWholeNumberOfTurns() {
        for runEnd in stride(from: 0.0, through: 3.0, by: 0.05) {
            let stop = ConversationsRefreshSpin.stopElapsedSeconds(runEndSeconds: runEnd)
            let turns = stop / period
            XCTAssertEqual(turns.rounded(), turns, accuracy: 1e-6, "runEnd \(runEnd) stop \(stop) is not a whole turn")
            XCTAssertGreaterThanOrEqual(stop, period - 1e-9, "runEnd \(runEnd) fell below one turn")
            XCTAssertGreaterThanOrEqual(stop + 1e-9, max(runEnd, period), "runEnd \(runEnd) stopped before the run ended")
        }
    }

    func testIsSpinningTrueWhileRunInFlight() {
        // A run still in flight (nil end) keeps spinning regardless of elapsed.
        XCTAssertTrue(ConversationsRefreshSpin.isSpinning(elapsedSeconds: 0, runEndSeconds: nil))
        XCTAssertTrue(ConversationsRefreshSpin.isSpinning(elapsedSeconds: period * 10, runEndSeconds: nil))
    }

    func testIsSpinningStopsAtTheBoundary() {
        // Ends before the first boundary -> still spinning; at/after it -> rest.
        XCTAssertTrue(ConversationsRefreshSpin.isSpinning(elapsedSeconds: period / 2, runEndSeconds: 0.02))
        XCTAssertFalse(ConversationsRefreshSpin.isSpinning(elapsedSeconds: period, runEndSeconds: 0.02))
        XCTAssertFalse(ConversationsRefreshSpin.isSpinning(elapsedSeconds: period + 0.1, runEndSeconds: 0.02))
    }
}
