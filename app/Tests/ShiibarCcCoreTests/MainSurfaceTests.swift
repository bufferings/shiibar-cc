import XCTest

@testable import ShiibarCcCore

/// Popover / window sizes, the message line and the row-verb outcomes
/// (M44 T1; DESIGN.md §4.5, §4.6 "message line", §9).
final class MainSurfaceTests: XCTestCase {
    // MARK: - §9 constants

    func testConstantsMatchSection9() {
        XCTAssertEqual(PopoverHeight.width, 420)
        XCTAssertEqual(PopoverHeight.initial, 640)
        XCTAssertEqual(PopoverHeight.minimum, 300)
        XCTAssertEqual(PopoverHeight.dragHandleHeight, 8)
        XCTAssertEqual(PopoverHeight.snapDistance, 12)
        XCTAssertEqual(MainWindowMetrics.initialWidth, 420)
        XCTAssertEqual(MainWindowMetrics.initialHeight, 640)
        XCTAssertEqual(MainWindowMetrics.minimumWidth, 360)
        XCTAssertEqual(MainWindowMetrics.minimumHeight, 300)
        XCTAssertEqual(MainWindowMetrics.listColumnWidth, 420)
        XCTAssertEqual(MainWindowMetrics.pageSlideSeconds, 0.22)
        XCTAssertEqual(ColumnMode.twoColumnMinimumWidth, 880)
        XCTAssertEqual(MainSurfaceRefresh.elapsedIntervalSeconds, 60)
        XCTAssertEqual(MainSurfaceRefresh.endedRowSecondRefetchSeconds, 2, "§9 second refetch after a Running row ends")
        XCTAssertEqual(MessageTransient.displaySeconds, 2)
        XCTAssertEqual(HistoryDisplayLimit.maxRows, 100, "§9 History row cap")
        XCTAssertFalse(WindowKeepOnTop.defaultEnabled)
        XCTAssertEqual(MainSurfaceDefaultsKeys.popoverHeight, "cc.shiibar.popoverHeight")
        XCTAssertEqual(MainSurfaceDefaultsKeys.windowKeepOnTop, "cc.shiibar.windowKeepOnTop")
        XCTAssertEqual(MainSurfaceDefaultsKeys.starredSessionIDs, "cc.shiibar.starredSessionIDs")
        XCTAssertEqual(MainSurfaceDefaultsKeys.mainWindowFrameAutosaveName, "cc.shiibar.mainWindow")
    }

    func testColumnModeThreshold() {
        let cases: [(Double, ColumnMode)] = [(360, .one), (879.5, .one), (880, .two), (1400, .two)]
        for (width, mode) in cases {
            XCTAssertEqual(ColumnMode.forWindowWidth(width), mode, "\(width)")
        }
    }

    // MARK: - Popover height

    func testHeightToOpen() {
        let cases: [(String, Double?, Double, Double)] = [
            ("nothing stored -> initial", nil, 1000, 640),
            ("zero stored -> initial", 0, 1000, 640),
            ("stored within range", 500, 1000, 500),
            ("stored below minimum", 200, 1000, 300),
            ("stored at minimum", 300, 1000, 300),
            ("stored above maximum opens at maximum", 1200, 900, 900),
            ("initial above maximum", nil, 600, 600),
            ("display shorter than minimum: fit the display", 500, 250, 250),
        ]
        for (name, stored, maximum, expected) in cases {
            XCTAssertEqual(PopoverHeight.heightToOpen(stored: stored, maximum: maximum), expected, name)
        }
    }

    func testClamp() {
        XCTAssertEqual(PopoverHeight.clamp(299, maximum: 900), 300)
        XCTAssertEqual(PopoverHeight.clamp(300, maximum: 900), 300)
        XCTAssertEqual(PopoverHeight.clamp(900, maximum: 900), 900)
        XCTAssertEqual(PopoverHeight.clamp(901, maximum: 900), 900)
    }

    func testSnapRangeBoundaries() {
        let cases: [(Double, Bool)] = [
            (627.9, false), (628, true), (635, true), (640, true), (645, true), (652, true), (652.1, false),
        ]
        for (height, inRange) in cases {
            XCTAssertEqual(PopoverHeight.isInSnapRange(height), inRange, "\(height)")
        }
    }

    func testDragFollowsSnapsAndFiresHapticOnEntry() {
        var drag = PopoverHeightDrag(startHeight: 500)
        struct Step { let delta: Double; let height: Double; let haptic: Bool }
        let steps = [
            Step(delta: 50, height: 550, haptic: false),
            Step(delta: 127.9, height: 627.9, haptic: false),
            Step(delta: 128, height: 640, haptic: true),    // enters at 628
            Step(delta: 145, height: 640, haptic: false),   // stays snapped
            Step(delta: 152, height: 640, haptic: false),   // 652: still inside
            Step(delta: 152.1, height: 652.1, haptic: false), // leaves: follows again
            Step(delta: 150, height: 640, haptic: true),    // enters again
            Step(delta: -400, height: 300, haptic: false),  // clamped to the minimum
            Step(delta: 900, height: 1000, haptic: false),  // clamped to the maximum
        ]
        for step in steps {
            let haptic = drag.update(dragDelta: step.delta, maximum: 1000)
            XCTAssertEqual(drag.height, step.height, accuracy: 0.0001, "delta \(step.delta)")
            XCTAssertEqual(haptic, step.haptic, "delta \(step.delta)")
        }
    }

    func testDragStartingInsideTheRangeDoesNotFireUntilReEntry() {
        var drag = PopoverHeightDrag(startHeight: 640)
        XCTAssertFalse(drag.update(dragDelta: 5, maximum: 1000))
        XCTAssertEqual(drag.height, 640)
        XCTAssertFalse(drag.update(dragDelta: 40, maximum: 1000))
        XCTAssertEqual(drag.height, 680)
        XCTAssertTrue(drag.update(dragDelta: 0, maximum: 1000))
    }

    func testOnlyAChangedHeightIsPersisted() {
        // A click without a drag (the popover shown display-clamped at 900
        // while 1200 is stored): nothing to persist (§9).
        var click = PopoverHeightDrag(startHeight: 900)
        XCTAssertNil(click.heightToPersist)
        _ = click.update(dragDelta: 0, maximum: 900)
        XCTAssertNil(click.heightToPersist, "a zero-travel drag changes nothing")
        // Dragging further down at the maximum is clamped back to the start.
        _ = click.update(dragDelta: 80, maximum: 900)
        XCTAssertNil(click.heightToPersist)

        var drag = PopoverHeightDrag(startHeight: 500)
        _ = drag.update(dragDelta: 30, maximum: 1000)
        XCTAssertEqual(drag.heightToPersist, 530)
    }

    // MARK: - Message line (§4.6 priority)

    func testMessageLinePriority() {
        let progress = (done: 340, total: 4200)
        let cases: [(String, (done: Int, total: Int)?, MessageLineError?, MessageTransient?, String?)] = [
            ("nothing -> hidden", nil, nil, nil, nil),
            ("progress beats everything", progress, .searchFailed, .refreshing, "Indexing 340 of 4,200…"),
            ("error beats transient", nil, .indexFailed, .updated(count: 3), "Indexing failed"),
            ("transient alone", nil, nil, .updated(count: 12), "Updated · 12 conversations"),
            ("refreshing", nil, nil, .refreshing, "Refreshing…"),
            ("rescan running", nil, nil, .rescan(.running), "Rescanning…"),
            ("rescan done", nil, nil, .rescan(.success), "✓ Rescan done"),
            ("rescan failed", nil, nil, .rescan(.failure), "Rescan failed"),
        ]
        for (name, progress, error, transient, expected) in cases {
            XCTAssertEqual(MessageLine.text(indexProgress: progress, error: error, transient: transient), expected, name)
        }
    }

    func testIndexProgressGrouping() {
        XCTAssertEqual(MessageLine.indexProgressText(done: 0, total: 0), "Indexing 0 of 0…")
        XCTAssertEqual(MessageLine.indexProgressText(done: 999, total: 1000), "Indexing 999 of 1,000…")
        XCTAssertEqual(MessageLine.indexProgressText(done: 123_456, total: 1_234_567), "Indexing 123,456 of 1,234,567…")
    }

    func testErrorTexts() {
        XCTAssertEqual(MessageLineError.jumpFailed.text, "Jump failed")
        XCTAssertEqual(MessageLineError.resumeFailed.text, "Resume failed")
        XCTAssertEqual(MessageLineError.branchFailed.text, "Branch failed")
        XCTAssertEqual(MessageLineError.searchFailed.text, "Search failed")
        XCTAssertEqual(MessageLineError.indexFailed.text, "Indexing failed")
    }

    // MARK: - Row verb outcomes (§4.5 / §4.6)

    func testInvocationOutcomes() {
        let jump = RowInvocation.jump(target: "iterm2:w0t0p0")
        let resume = RowInvocation.resume(sessionID: "s", cwd: "/Users/example/a")
        let branch = RowInvocation.branch(sessionID: "s", cwd: "/Users/example/a")
        let cases: [(RowInvocation, Int32, RowInvocationOutcome, Bool)] = [
            (jump, 0, .succeeded(refetchHistory: false), true),
            (jump, 1, .failed(.jumpFailed), false),
            (jump, 2, .targetNotFound, false),
            (jump, 3, .permissionDenied, false),
            (resume, 0, .succeeded(refetchHistory: true), true),
            (resume, 1, .failed(.resumeFailed), false),
            (resume, 2, .failed(.resumeFailed), false),
            (resume, 3, .permissionDenied, false),
            (branch, 0, .succeeded(refetchHistory: true), true),
            (branch, 1, .failed(.branchFailed), false),
            (branch, 3, .permissionDenied, false),
        ]
        for (invocation, code, outcome, closes) in cases {
            let result = RowInvocationOutcome.classify(invocation, exitCode: code)
            XCTAssertEqual(result, outcome, "\(invocation) exit \(code)")
            XCTAssertEqual(result.closesPopover, closes, "\(invocation) exit \(code)")
        }
    }
}
