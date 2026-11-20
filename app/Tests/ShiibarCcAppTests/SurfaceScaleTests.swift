import CoreGraphics
import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The scaled dimensions at text size 13 are window-design.html's values
/// (DESIGN.md §4.5 "text size"), and every one follows the ratio.
final class SurfaceScaleTests: XCTestCase {
    private static let valuesAtBase: [(String, KeyPath<SurfaceScale, CGFloat>, CGFloat)] = [
        ("headerTop", \.headerTop, 10),
        ("headerBottom", \.headerBottom, 8),
        ("searchFieldHeight", \.searchFieldHeight, 28),
        ("headerButton", \.headerButton, 24),
        ("headerIcon", \.headerIcon, 15),
        ("headerIconLine", \.headerIconLine, 1.4),
        ("pinIconLine", \.pinIconLine, 1.2),
        ("menuChevronLine", \.menuChevronLine, 1.6),
        ("headerRowHeight", \.headerRowHeight, 28),
        ("windowDetailPaneHeaderRowHeight", \.windowDetailPaneHeaderRowHeight, 32),
        ("searchFieldFont", \.searchFieldFont, 12),
        ("searchIcon", \.searchIcon, 13),
        ("searchIconLine", \.searchIconLine, 1.4),
        ("searchClearButton", \.searchClearButton, 12),
        ("listNoteFont", \.listNoteFont, 12),
        ("emptyStateVertical", \.emptyStateVertical, 8),
        ("hiddenRowsVertical", \.hiddenRowsVertical, 6),
        ("listBottom", \.listBottom, 8),
        ("sectionTitleFont", \.sectionTitleFont, 12),
        ("sectionCountFont", \.sectionCountFont, 11),
        ("sectionHeaderTop", \.sectionHeaderTop, 8),
        ("sectionHeaderBottom", \.sectionHeaderBottom, 6),
        ("subHeadingTop", \.subHeadingTop, 6),
        ("subHeadingBottom", \.subHeadingBottom, 4),
        ("sectionBandVertical", \.sectionBandVertical, 4),
        ("sectionChevronBox", \.sectionChevronBox, 14),
        ("sectionChevronIcon", \.sectionChevronIcon, 12),
        ("sectionChevronLine", \.sectionChevronLine, 1.8),
        ("runningMark", \.runningMark, 7),
        ("refusalTipFont", \.refusalTipFont, 12),
        ("refusalTipVertical", \.refusalTipVertical, 4),
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
        ("rowTop", \.rowTop, 8),
        ("rowBottom", \.rowBottom, 9),
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
        for ratio: CGFloat in [9.0 / 13.0, 18.0 / 13.0] {
            let scale = SurfaceScale(ratio: ratio)
            for (name, path, value) in Self.valuesAtBase {
                XCTAssertEqual(scale[keyPath: path], value * ratio, accuracy: 1e-9, "\(name) at \(ratio * 13)")
            }
        }
    }

    /// window-design.html "collapsing sections and the row drag": two
    /// neighbors are apart by the larger of the upper one's space below and
    /// the lower one's space above (band and plain headings 8 / 6, Starred
    /// and Recent headings 6 / 4, frames none), following the text size.
    func testTheSpaceBetweenBlocks() {
        func heading(_ heading: ListHeading, _ style: ListHeadingStyle) -> ListBlock {
            .heading(ListHeadingModel(heading: heading, style: style, countText: nil))
        }
        let frame = ListBlock.frame(ListFrameModel(id: .starred, rows: []))
        let blocks: [ListBlock] = [
            heading(.running, .band), frame, heading(.history, .band), heading(.starred, .sub), frame,
            heading(.recent, .sub), frame, .moreLine("1 more"),
        ]
        let expected: [CGFloat] = [8, 6, 8, 6, 4, 6, 4, 0]
        for scale in [SurfaceScale.base, SurfaceScale(ratio: 18.0 / 13.0)] {
            let ratio = scale.sectionHeaderTop / 8
            for (index, value) in expected.enumerated() {
                XCTAssertEqual(ListBlockSpacing.gap(before: index, in: blocks, scale: scale), value * ratio,
                               accuracy: 1e-9, "block \(index)")
            }
        }
        let closed: [ListBlock] = [heading(.running, .band), heading(.history, .band), heading(.starred, .sub),
                                   heading(.recent, .sub)]
        XCTAssertEqual((0..<4).map { ListBlockSpacing.gap(before: $0, in: closed, scale: .base) }, [8, 8, 6, 6],
                       "closed band under a band: 8; closed Starred under History: 6; Recent under a closed Starred: 6")
        let searching: [ListBlock] = [heading(.running, .plain), frame, heading(.history, .plain), frame]
        XCTAssertEqual((0..<4).map { ListBlockSpacing.gap(before: $0, in: searching, scale: .base) }, [8, 6, 8, 6])
    }

    func testFixedValues() {
        XCTAssertEqual(SurfaceMetrics.rowLeading, 11)
        XCTAssertEqual(SurfaceMetrics.rowTrailing, 8)
        XCTAssertEqual(SurfaceMetrics.rowColumnSpacing, 8, "`.row` gap")
        XCTAssertEqual(SurfaceMetrics.headerSide, 10)
        XCTAssertEqual(SurfaceMetrics.windowTrafficLightCenter, 26)
        XCTAssertEqual(SurfaceMetrics.trafficLightsWidth, 78)
        XCTAssertEqual(SurfaceMetrics.headerSpacing, 8, "`.hrow` gap")
        XCTAssertEqual(SurfaceMetrics.windowHeaderMinimumPadding, 6)
    }

    /// The search field is 28pt at 13 and follows the text size.
    func testSearchFieldHeightAtEachTextSize() {
        for points in [9.0, 13.0, 18.0] {
            XCTAssertEqual(SurfaceScale(ratio: CGFloat(points / 13)).searchFieldHeight, CGFloat(28 * points / 13),
                           accuracy: 1e-9, "\(points)")
        }
        XCTAssertEqual(SurfaceScale(ratio: 9.0 / 13.0).searchFieldHeight, 252.0 / 13.0, accuracy: 1e-9)
    }

    /// The window header row (search field and buttons, both scaled) is
    /// centered on the traffic lights with equal space above and below:
    /// 52pt in all at every text size here, since the row stays under
    /// 52 − 2 × 6.
    func testWindowHeaderIsSymmetricAboutTheTrafficLights() {
        let cases: [(Double, CGFloat)] = [(9, 26 - 14 * 9 / 13), (13, 12), (18, 26 - 14 * 18 / 13)]
        for (points, padding) in cases {
            let scale = SurfaceScale(ratio: CGFloat(points / 13))
            XCTAssertEqual(scale.headerRowHeight, max(scale.searchFieldHeight, scale.headerButton), "\(points)")
            XCTAssertEqual(scale.windowHeaderPadding, padding, accuracy: 1e-9, "\(points)")
            XCTAssertEqual(scale.windowHeaderPadding + scale.headerRowHeight / 2, 26, accuracy: 1e-9,
                           "\(points): centered on the traffic lights")
            XCTAssertEqual(2 * scale.windowHeaderPadding + scale.headerRowHeight, 52, accuracy: 1e-9,
                           "\(points): 52pt header")
        }
    }

    /// The detail page's header row (32pt title block at 13) follows the
    /// same rule; at 18 (44.3pt) the 6pt minimum holds and the header grows.
    func testWindowDetailPaneHeaderFollowsTheSameRule() {
        let base = SurfaceScale.base
        XCTAssertEqual(base.windowDetailPaneHeaderPadding, 10)
        let small = SurfaceScale(ratio: 9.0 / 13.0)
        XCTAssertEqual(small.windowDetailPaneHeaderPadding, 26 - 16 * 9.0 / 13.0, accuracy: 1e-9)
        let large = SurfaceScale(ratio: 18.0 / 13.0)
        XCTAssertEqual(large.windowDetailPaneHeaderRowHeight, 32 * 18.0 / 13.0, accuracy: 1e-9)
        XCTAssertEqual(large.windowDetailPaneHeaderPadding, 6, "the minimum: the header grows")
        XCTAssertGreaterThan(2 * large.windowDetailPaneHeaderPadding + large.windowDetailPaneHeaderRowHeight, 52)
    }

    func testWindowHeaderPaddingRule() {
        XCTAssertEqual(SurfaceScale.windowHeaderPadding(contentHeight: 28), 12)
        XCTAssertEqual(SurfaceScale.windowHeaderPadding(contentHeight: 40), 6, "exactly the minimum")
        XCTAssertEqual(SurfaceScale.windowHeaderPadding(contentHeight: 50), 6, "taller: the minimum, the header grows")
    }
}
