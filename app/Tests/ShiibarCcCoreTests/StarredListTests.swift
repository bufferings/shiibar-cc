import XCTest

@testable import ShiibarCcCore

/// The stars as an ordered list (DESIGN.md §4.6 "stars", §8.60): a new star
/// goes to the end, removing and pruning keep the others' order, the
/// unordered set an earlier app version stored is shown and saved newest
/// first, and the stored values are read defensively.
final class StarredListTests: XCTestCase {
    /// Search order (newest first): n0, n1, n2, n3.
    private let results = (0..<4).map { UL.summary("n\($0)", updatedAt: Int64(9_000 - $0)) }

    // MARK: - Order rules

    func testANewStarGoesToTheEnd() {
        let list: StarredList = ["n3", "n1"]
        XCTAssertEqual(list.toggled("n0", results: results).sessionIDs, ["n3", "n1", "n0"])
    }

    func testRemovingAStarKeepsTheOthersInOrder() {
        let list: StarredList = ["n3", "n0", "n1"]
        XCTAssertEqual(list.toggled("n0", results: results).sessionIDs, ["n3", "n1"])
        XCTAssertEqual(list.removing("n3", results: results)?.sessionIDs, ["n0", "n1"])
        XCTAssertNil(list.removing("n2", results: results), "not starred: nothing to remove")
    }

    func testPruningKeepsTheOthersInOrder() {
        let list: StarredList = ["n3", "gone", "n0", "n1"]
        XCTAssertEqual(list.pruned(browseResults: results)?.sessionIDs, ["n3", "n0", "n1"])
        XCTAssertNil(StarredList(["n3", "n0"]).pruned(browseResults: results), "nothing pruned: nothing to save")
        XCTAssertEqual(StarredList(["n0"]).pruned(browseResults: [])?.sessionIDs, [])
    }

    func testARepeatedSessionIDCountsOnceAtItsFirstPlace() {
        XCTAssertEqual(StarredList(["b", "a", "b", "c", "a"]).sessionIDs, ["b", "a", "c"])
    }

    private let shownABCD = ["a", "b", "c", "d"]

    func testMovingPlacesTheRowBeforeTheTarget() {
        let list: StarredList = ["a", "b", "c", "d"]
        XCTAssertEqual(list.moving("d", before: "b", shown: shownABCD, results: [])?.sessionIDs, ["a", "d", "b", "c"])
        XCTAssertEqual(list.moving("a", before: nil, shown: shownABCD, results: [])?.sessionIDs, ["b", "c", "d", "a"])
        XCTAssertEqual(list.moving("a", before: "d", shown: shownABCD, results: [])?.sessionIDs, ["b", "c", "a", "d"])
        XCTAssertEqual(list.moving("new", before: "c", shown: shownABCD, results: [])?.sessionIDs, ["a", "b", "new", "c", "d"],
                       "a Recent row is starred at the place")
        XCTAssertEqual(list.moving("new", before: nil, shown: shownABCD, results: [])?.sessionIDs, ["a", "b", "c", "d", "new"])
    }

    func testAMoveThatKeepsTheOrderChangesNothing() {
        let list: StarredList = ["a", "b", "c"]
        XCTAssertNil(list.moving("b", before: "b", shown: shownABCD, results: []), "onto itself")
        XCTAssertNil(list.moving("b", before: "c", shown: shownABCD, results: []), "right before its own next")
        XCTAssertNil(list.moving("c", before: nil, shown: shownABCD, results: []), "the last row to the end")
        XCTAssertNil(list.moving("a", before: "zzz", shown: shownABCD, results: []), "an unknown target")
    }

    /// A hidden (running) star between shown rows: a drop that leaves the
    /// displayed order as it is changes nothing, so the hidden one keeps its
    /// place.
    func testADropAtTheSameDisplayedPlaceWithAHiddenStarChangesNothing() {
        let list: StarredList = ["a", "b", "s1", "c"]
        let shown = ["a", "b", "c"]
        XCTAssertNil(list.moving("b", before: "c", shown: shown, results: []), "b on its own lower half")
        XCTAssertNil(list.moving("c", before: nil, shown: shown, results: []), "c to the end")
        XCTAssertEqual(list.moving("c", before: "b", shown: shown, results: [])?.sessionIDs, ["a", "c", "b", "s1"])
        let last: StarredList = ["a", "L", "s1"]
        XCTAssertNil(last.moving("L", before: nil, shown: ["a", "L"], results: []), "L on its own lower half")
        XCTAssertEqual(last.moving("a", before: nil, shown: ["a", "L"], results: [])?.sessionIDs, ["L", "s1", "a"])
    }

    // MARK: - The unordered stored value

    func testAnUnorderedListIsOrderedNewestFirstThenBySessionID() {
        let list = StarredList.unordered(["n2", "zz-old", "n0", "aa-old"])
        XCTAssertTrue(list.isUnordered)
        let ordered = list.materialized(results: results)
        XCTAssertFalse(ordered.isUnordered)
        XCTAssertEqual(ordered.sessionIDs, ["n0", "n2", "aa-old", "zz-old"],
                       "conversations in the result newest first, the others by session ID after them")
    }

    func testAStarChangeOnAnUnorderedListOrdersItFirst() {
        // §4.6 "stars": a change before the first browse save keeps every
        // star (none lost), orders them, then applies the change.
        let list = StarredList.unordered(["n2", "old", "n0"])
        let starred = list.toggled("n3", results: results)
        XCTAssertEqual(starred.sessionIDs, ["n0", "n2", "old", "n3"])
        XCTAssertFalse(starred.isUnordered)
        XCTAssertEqual(list.toggled("n0", results: results).sessionIDs, ["n2", "old"])
        XCTAssertEqual(list.moving("old", before: "n0", shown: ["n0", "n2"], results: results)?.sessionIDs, ["old", "n0", "n2"])
    }

    func testPruningAnUnorderedListSavesItNewestFirst() {
        let list = StarredList.unordered(["n2", "n0"])
        XCTAssertEqual(list.pruned(browseResults: results), StarredList(["n0", "n2"]),
                       "saved even when nothing is pruned: it becomes the ordered list")
    }

    // MARK: - Stored values

    func testLoadReadsTheOrderedListAndLeavesTheUnorderedValueUnused() {
        let defaults = InMemoryDefaults()
        defaults.set(["x"], forKey: MainSurfaceDefaultsKeys.starredSessionIDs)
        defaults.set(["b", "a", "b"], forKey: MainSurfaceDefaultsKeys.starredSessionList)
        XCTAssertEqual(StarredSessions.load(from: defaults), StarredList(["b", "a"]))
    }

    func testLoadFallsBackToTheUnorderedValue() {
        struct Case {
            let name: String
            let ordered: Any?
            let unordered: Any?
            let expected: StarredList
        }
        let cases = [
            Case(name: "nothing stored", ordered: nil, unordered: nil, expected: StarredList()),
            Case(name: "only the unordered set", ordered: nil, unordered: ["b", "a"], expected: .unordered(["a", "b"])),
            Case(name: "an ordered value that is not an array", ordered: "a", unordered: ["c"], expected: .unordered(["c"])),
            Case(name: "an ordered array with a non-string", ordered: ["a", 1] as [Any], unordered: ["c"],
                 expected: .unordered(["c"])),
            Case(name: "a broken ordered value, no unordered set", ordered: 42, unordered: nil, expected: StarredList()),
            Case(name: "an empty ordered list wins", ordered: [String](), unordered: ["c"], expected: StarredList()),
        ]
        for c in cases {
            let defaults = InMemoryDefaults()
            if let ordered = c.ordered { defaults.set(ordered, forKey: MainSurfaceDefaultsKeys.starredSessionList) }
            if let unordered = c.unordered { defaults.set(unordered, forKey: MainSurfaceDefaultsKeys.starredSessionIDs) }
            XCTAssertEqual(StarredSessions.load(from: defaults), c.expected, c.name)
        }
    }

    func testSaveWritesTheOrderedListOnly() {
        let defaults = InMemoryDefaults()
        defaults.set(["old"], forKey: MainSurfaceDefaultsKeys.starredSessionIDs)
        StarredSessions.save(["b", "a"], to: defaults)
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.starredSessionList) as? [String], ["b", "a"])
        XCTAssertEqual(defaults.stringArray(forKey: MainSurfaceDefaultsKeys.starredSessionIDs), ["old"],
                       "the unordered value is never removed")
    }

    // MARK: - In the list state

    func testTheStateShowsAnUnorderedListNewestFirstAndSavesItOnTheBrowseList() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: .unordered(["n3", "n1", "gone"]))
        let filtered = state.handle(.historyDelivered(Array(results.prefix(3)), isFiltered: true))
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["n1"], "searching: the result only")
        XCTAssertEqual(filtered, [], "a filtered result saves nothing")
        XCTAssertTrue(state.stars.isUnordered)
        let effects = state.handle(.historyDelivered(results, isFiltered: false))
        XCTAssertEqual(effects, [.persistStars(["n1", "n3"])])
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["n1", "n3"])
        XCTAssertFalse(state.stars.isUnordered)
        XCTAssertEqual(state.handle(.historyDelivered(results, isFiltered: false)), [], "saved once")
    }

    func testAStarChangeBeforeTheBrowseListKeepsEveryStar() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: .unordered(["n3", "elsewhere"]))
        state.handle(.historyDelivered(Array(results.prefix(1)) + [results[3]], isFiltered: true))
        let effects = state.handle(.starToggled(sessionID: "n0"))
        XCTAssertEqual(effects, [.persistStars(["n3", "elsewhere", "n0"])])
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["n3", "n0"])
    }

    func testPruningOnlyOnTheBrowseList() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["n1", "gone", "n0"])
        let filtered = state.handle(.historyDelivered([results[1]], isFiltered: true))
        XCTAssertEqual(state.stars, ["n1", "gone", "n0"], "a filtered result never prunes")
        XCTAssertEqual(filtered, [])
        let browse = state.handle(.historyDelivered(results, isFiltered: false))
        XCTAssertEqual(state.stars, ["n1", "n0"])
        XCTAssertEqual(browse, [.persistStars(["n1", "n0"])])
        XCTAssertEqual(state.handle(.historyDelivered(results, isFiltered: false)), [], "nothing to persist when unchanged")
    }
}
