import XCTest
@testable import ShiibarCcCore

final class SoundCatalogTests: XCTestCase {
    func testDefaultSoundNameIsGlass() {
        // DESIGN.md §4.5/§9: both Waiting and Done default to Glass, so the
        // pre-M14 notification sound doesn't change for anyone who never
        // opens Settings.
        XCTAssertEqual(SoundCatalog.defaultSoundName, "Glass")
    }

    func testFallbackIsGlassOnly() {
        // DESIGN.md §4.5: if enumeration fails, fall back to a single choice of Glass only.
        XCTAssertEqual(SoundCatalog.fallback, ["Glass"])
    }

    func testNamesStripsExtensionsAndSorts() {
        let names = SoundCatalog.names(fromFilenames: ["Ping.aiff", "Glass.aiff", "Basso.aiff"])
        XCTAssertEqual(names, ["Basso", "Glass", "Ping"])
    }

    func testNamesDeduplicatesSameStemDifferentExtensions() {
        let names = SoundCatalog.names(fromFilenames: ["Glass.aiff", "Glass.wav"])
        XCTAssertEqual(names, ["Glass"])
    }

    func testNamesOfEmptyListingIsEmpty() {
        XCTAssertEqual(SoundCatalog.names(fromFilenames: []), [])
    }
}
