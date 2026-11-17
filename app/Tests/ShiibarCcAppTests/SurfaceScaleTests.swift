import CoreGraphics
import XCTest
@testable import ShiibarCcApp

/// The scaled dimensions at text size 13 are window-design.html's values
/// (DESIGN.md §4.5 "text size"), and every one follows the ratio.
final class SurfaceScaleTests: XCTestCase {
    private static let valuesAtBase: [(String, KeyPath<SurfaceScale, CGFloat>, CGFloat)] = [
        ("headerTop", \.headerTop, 10),
        ("headerBottom", \.headerBottom, 8),
        ("searchFieldHeight", \.searchFieldHeight, 24),
        ("searchFieldFont", \.searchFieldFont, 12),
        ("searchIcon", \.searchIcon, 13),
        ("searchIconLine", \.searchIconLine, 1.4),
        ("searchClearButton", \.searchClearButton, 12),
        ("listNoteFont", \.listNoteFont, 12),
        ("emptyStateVertical", \.emptyStateVertical, 8),
        ("hiddenRowsVertical", \.hiddenRowsVertical, 6),
        ("listBottom", \.listBottom, 8),
        ("rowGap", \.rowGap, 6),
        ("sectionTitleFont", \.sectionTitleFont, 12),
        ("sectionCountFont", \.sectionCountFont, 11),
        ("sectionHeaderTop", \.sectionHeaderTop, 10),
        ("sectionHeaderBottom", \.sectionHeaderBottom, 6),
        ("rowSymbolColumn", \.rowSymbolColumn, 28),
        ("rowSymbol", \.rowSymbol, 20),
        ("rowSymbolTop", \.rowSymbolTop, 1),
        ("star", \.star, 16),
        ("starFilledLine", \.starFilledLine, 0.7),
        ("starOutlineLine", \.starOutlineLine, 1.1),
        ("rowTitleFont", \.rowTitleFont, 13),
        ("rowLabelFont", \.rowLabelFont, 11),
        ("rowPromptFont", \.rowPromptFont, 11),
        ("rowLabelTitleSpacing", \.rowLabelTitleSpacing, 1),
        ("rowTitlePromptSpacing", \.rowTitlePromptSpacing, 4),
        ("rowTitleHeight", \.rowTitleHeight, 17.55),
        ("rowLabelHeight", \.rowLabelHeight, 15.95),
        ("rowPromptHeight", \.rowPromptHeight, 15.95),
        ("rowCardTop", \.rowCardTop, 8),
        ("rowCardBottom", \.rowCardBottom, 9),
        ("statusLineFont", \.statusLineFont, 12),
        ("messageLineFont", \.messageLineFont, 11),
        ("statusLineTop", \.statusLineTop, 7),
        ("panelStatusBottom", \.panelStatusBottom, 7),
        ("footerHintsTop", \.footerHintsTop, 7),
        ("footerHintsBottom", \.footerHintsBottom, 9),
        ("keyChipFont", \.keyChipFont, 10.5),
        ("keyChipVertical", \.keyChipVertical, 1),
        ("keyLabelFont", \.keyLabelFont, 11),
        ("panelTop", \.panelTop, 9),
        ("panelBottom", \.panelBottom, 10),
        ("panelButtonFont", \.panelButtonFont, 13),
        ("primaryButtonMinWidth", \.primaryButtonMinWidth, 84),
        ("primaryButtonVertical", \.primaryButtonVertical, 5),
        ("branchButtonVertical", \.branchButtonVertical, 4),
        ("paneTitleDetailFont", \.paneTitleDetailFont, 13.5),
        ("paneTitleColumnFont", \.paneTitleColumnFont, 15),
        ("paneLabelFont", \.paneLabelFont, 11),
        ("panePositionFont", \.panePositionFont, 11),
        ("paneTitleSpacing", \.paneTitleSpacing, 1),
        ("paneHeaderTopDetail", \.paneHeaderTopDetail, 9),
        ("paneHeaderTopColumn", \.paneHeaderTopColumn, 11),
        ("paneHeaderBottom", \.paneHeaderBottom, 8),
        ("paneTitleBlockHeight", \.paneTitleBlockHeight, 32),
        ("stepperSegmentWidth", \.stepperSegmentWidth, 26),
        ("stepperSegmentHeight", \.stepperSegmentHeight, 22),
        ("stepperIcon", \.stepperIcon, 13),
        ("stepperIconLine", \.stepperIconLine, 1.5),
        ("findBarFont", \.findBarFont, 11),
        ("findBarVertical", \.findBarVertical, 5),
        ("centeredLineFont", \.centeredLineFont, 12),
    ]

    func testValuesAtThirteen() {
        for (name, path, value) in Self.valuesAtBase {
            XCTAssertEqual(SurfaceScale.base[keyPath: path], value, accuracy: 1e-9, name)
        }
    }

    func testEveryValueFollowsTheRatioUnrounded() {
        let ratio: CGFloat = 18.0 / 13.0
        let large = SurfaceScale(ratio: ratio)
        for (name, path, value) in Self.valuesAtBase {
            XCTAssertEqual(large[keyPath: path], value * ratio, accuracy: 1e-9, name)
        }
    }

    func testFixedValues() {
        XCTAssertEqual(SurfaceMetrics.headerSide, 10)
        XCTAssertEqual(SurfaceMetrics.windowTrafficLightCenter, 26)
        XCTAssertEqual(SurfaceMetrics.trafficLightsWidth, 78)
        XCTAssertEqual(SurfaceMetrics.headerButton, 24)
    }

    func testWindowHeaderTopsKeepTheirCenters() {
        let base = SurfaceScale.base
        XCTAssertEqual(base.headerRowHeight, 24)
        XCTAssertEqual(base.windowHeaderTop, 14)
        XCTAssertEqual(base.windowPaneHeaderTop(isDetailPage: true), 10)
        XCTAssertEqual(base.windowPaneHeaderTop(isDetailPage: false), 11)
        for points in [9.0, 13.0, 18.0] {
            let scale = SurfaceScale(ratio: CGFloat(points / 13))
            XCTAssertEqual(scale.windowHeaderTop + scale.headerRowHeight / 2, 26, accuracy: 1e-9, "\(points)")
            XCTAssertEqual(scale.windowPaneHeaderTop(isDetailPage: false) + scale.paneTitleBlockHeight / 2, 27,
                           accuracy: 1e-9, "\(points)")
        }
        // At 9 the 24pt header buttons are taller than the search field.
        XCTAssertEqual(SurfaceScale(ratio: 9.0 / 13.0).headerRowHeight, 24)
    }
}
