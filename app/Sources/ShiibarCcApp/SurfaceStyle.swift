// Colors, metrics and line-art icons for the popover and the window
// (visual spec: docs/window-design.html). The CSS values there are paper
// examples for colors — the implementation follows the system colors and
// the accent color (window-design.html "implementation notes"); the star
// yellow uses the page's values, and the two state colors are
// `systemOrange` (waiting) and `controlAccentColor` (unreviewed — DESIGN.md
// §3.1, §9 "state colors"). Sizes and spacing follow the mock's CSS.

import AppKit
import ShiibarCcCore
import SwiftUI

enum SurfaceColors {
    /// The list's pale, opaque ground in the popover and the window
    /// (window-design.html "implementation notes": light = the control
    /// background with 10% system gray; dark = the window background with
    /// 30% black), so white row frames stand out on light and veiled ones on
    /// dark. The popover paints its arrow with the same color.
    static let listBackgroundNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: .black) ?? .windowBackgroundColor
            : NSColor.controlBackgroundColor.blended(withFraction: lightListGrayFraction, of: .systemGray)
                ?? .windowBackgroundColor
    }
    /// The share of gray in the light list ground (window-design.html
    /// "implementation notes": 10%): dark enough that the white row frames
    /// read against it, with the bands darker still.
    static let lightListGrayFraction: CGFloat = 0.10
    static let listBackground = Color(nsColor: listBackgroundNSColor)
    /// The conversation pane: the plain reading background.
    static let paneBackground = Color(nsColor: .controlBackgroundColor)
    /// A row frame's ground (window-design.html "implementation notes"):
    /// the control background on light; on dark, white at
    /// `darkCardWhiteOpacity` over the list ground, so on dark the list
    /// ground, the band and the row frame get lighter in that order.
    static let cardNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(darkCardWhiteOpacity)
            : NSColor.controlBackgroundColor
    }
    static let darkCardWhiteOpacity: CGFloat = 0.10
    static let card = Color(nsColor: cardNSColor)
    static let cardBorderNSColor = NSColor.separatorColor
    static let cardBorder = Color(nsColor: cardBorderNSColor)
    /// Selected row ground while the list has focus: a pale accent tint
    /// (window-design.html `.sel`; DESIGN.md §4.5 "row selection").
    static let selectionTint = Color.accentColor.opacity(0.16)
    /// Selected row ground while the search field has focus: a pale neutral
    /// gray, the inactive-selection look (window-design.html `.sel.inact`).
    /// Slightly denser on dark, where the veiled frames are close in value.
    static let inactiveSelectionTint = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor.systemGray.withAlphaComponent(
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.26 : 0.18)
    })
    static let line = Color(nsColor: .separatorColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    /// Neutral chip / key-hint ground (`rgba(127,127,127,.09)`).
    static let chip = Color.gray.opacity(0.09)
    /// The heading band's ground, drawn over the list's ground
    /// (window-design.html "implementation notes": the system gray at 0.12
    /// on light, 0.08 on dark). Its top and bottom lines are `line`.
    static let sectionBand = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor.systemGray.withAlphaComponent(sectionBandOpacity(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua))
    })
    static func sectionBandOpacity(dark: Bool) -> CGFloat { dark ? 0.08 : 0.12 }
    /// The more button's box while its menu is open (window-design.html
    /// `.sym.open`: gray at 16%).
    static let moreButtonOpenGround = Color.gray.opacity(0.16)
    /// The waiting color (DESIGN.md §3.1, §9 "state colors"): the waiting
    /// status symbol, the Running mark and the tray dot.
    static let waitingNSColor = NSColor.systemOrange
    /// The unreviewed color (DESIGN.md §3.1, §9 "state colors"): a row's
    /// unreviewed dot, the Running mark and the tray dot.
    static let unreviewedNSColor = NSColor.controlAccentColor
    /// The color of a dot that stands for several sessions (the closed
    /// Running heading's mark — DESIGN.md §4.5 "collapsing sections").
    static func stateDot(_ dot: StateDot) -> Color {
        switch dot {
        case .waiting: return Color(nsColor: waitingNSColor)
        case .unreviewed: return Color(nsColor: unreviewedNSColor)
        }
    }
    /// A hovered row's ground (window-design.html `.row.hov`: gray at 9%),
    /// paler than the gray selection ground.
    static let rowHover = Color.gray.opacity(0.09)
    /// The reason a row cannot be dragged (`.tip`): a dark ground with light
    /// text on light, a light ground with dark text on dark.
    static let refusalTipGround = Color(nsColor: .labelColor)
    static let refusalTipText = Color(nsColor: .textBackgroundColor)
    /// §8.49: yellow is for stars only (page values).
    static let starFill = Color(red: 0xF5 / 255, green: 0xB4 / 255, blue: 0x00 / 255)
    static let starLine = Color(red: 0xD3 / 255, green: 0x97 / 255, blue: 0x00 / 255)
}

/// Dimensions that do not follow the text size (DESIGN.md §4.5 "text size"):
/// horizontal paddings and gaps (the gaps between the header buttons
/// included), corner radii (the header buttons' hover ground included),
/// border widths, and parts the OS draws.
enum SurfaceMetrics {
    /// `.hrow` horizontal padding 10.
    static let headerSide: CGFloat = 10
    /// In the window the header row shares its vertical center with the
    /// traffic lights (§4.5 "header row"). The window uses the unified
    /// title bar (52pt), whose buttons are centered 26pt from the top; the
    /// OS draws them at one size whatever the text size.
    static let windowTrafficLightCenter: CGFloat = 26
    /// Space the traffic lights take at the leading edge of a header.
    static let trafficLightsWidth: CGFloat = 78
    /// The window header's smallest space above and below its row: the
    /// header grows (its row's center moves below the traffic lights') only
    /// when the row is too tall for the 52pt title bar area with this
    /// space.
    static let windowHeaderMinimumPadding: CGFloat = 6
    /// `.hrow` gap between its items (fixed; the buttons' corner radius 7 is
    /// fixed too — `HoverChipButtonStyle`).
    static let headerSpacing: CGFloat = 8
    /// The list's horizontal padding (`.rows`): the row frames and the
    /// text-and-line headings sit this far in from the list's edges; the
    /// bands do not (they span the list's whole width).
    static let listSide: CGFloat = 10
    /// 8 between a heading's parts (`.rows .sec` gap).
    static let sectionBandSpacing: CGFloat = 8
    /// The band (Running, History and the Archive view's band —
    /// window-design.html `.rows .sec`): inner left 22 / right 19, so the
    /// name starts where the rows' text does and the chevron ends where the
    /// rows' symbol-and-time column does. Lines 1pt along its top and
    /// bottom edges; 8 above and below it, whatever the text size (§9).
    static let sectionBandLeading: CGFloat = listSide + rowFrameBorder + rowLeading
    static let sectionBandTrailing: CGFloat = listSide + rowFrameBorder + rowTrailing
    static let sectionBandLine: CGFloat = 1
    static let sectionBandGap: CGFloat = 8
    /// The text-and-line heading (Starred and Recent — `.sec.sub`): inner
    /// left 12 / right 9 from the frames' edges (the band's name and
    /// chevron places), and the radius of its drop-target emphasis.
    static let subHeadingLeading: CGFloat = rowFrameBorder + rowLeading
    static let subHeadingTrailing: CGFloat = rowFrameBorder + rowTrailing
    static let subHeadingRadius: CGFloat = 6
    /// Between the star's box and the more button's box (`.rc .tops` gap 4).
    static let rowSymbolBoxSpacing: CGFloat = 4
    /// The more button's box while its menu is open: radius 5.
    static let moreButtonOpenRadius: CGFloat = 5
    /// A frame of rows (`.group`): radius 10, a 1pt border; the rows'
    /// grounds stay inside its corners (radius 9). The divider between two
    /// rows starts at the rows' text (11 in from the border) and runs to the
    /// border on the right.
    static let rowFrameRadius: CGFloat = 10
    static let rowFrameBorder: CGFloat = 1
    static let rowInnerRadius: CGFloat = 9
    static let rowLeading: CGFloat = 11
    static let rowTrailing: CGFloat = 8
    /// Between a row's three lines and its symbol-and-time column (`.row`
    /// gap 8; fixed — horizontal spacing does not follow the text size).
    static let rowColumnSpacing: CGFloat = 8
    /// The row drag's drop line (`.dropline`): 2pt thick, centered on the
    /// row boundary, starting 3pt left of the frame with an 8pt ring (2pt
    /// line) on its left end and ending at the frame's right edge. The
    /// emphasized heading's inner border and the emphasized frame's border
    /// are 2pt (`.sec.over`, `.group.over`). None of these follow the text
    /// size (DESIGN.md §4.5 "text size").
    static let dropLineWidth: CGFloat = 2
    static let dropLineLeadOut: CGFloat = 3
    static let dropRingDiameter: CGFloat = 8
    static let dropRingLine: CGFloat = 2
    static let dropHeaderBorder: CGFloat = 2
    /// The reason a row cannot be dragged (`.tip`): 9 inside on the sides,
    /// radius 6, its top-left corner 12 right of and 16 below the pointer.
    static let refusalTipHorizontal: CGFloat = 9
    static let refusalTipRadius: CGFloat = 6
    static let refusalTipOffsetX: CGFloat = 12
    static let refusalTipOffsetY: CGFloat = 16
}

/// Dimensions that follow the text size (DESIGN.md §4.5 "text size"): each
/// property is its window-design.html value at text size 13 times `ratio`.
/// Font sizes, row heights, vertical paddings and gaps, icons and symbols,
/// the search field height, the header buttons and the pane header's back
/// button with their icons (line widths included), and the primary
/// button's minimum width. Views
/// read it from the environment (`\.surfaceScale`), which the two roots set
/// from the text size.
struct SurfaceScale: Equatable {
    /// `TextSize.ratio`: 1 at text size 13.
    let ratio: CGFloat

    static let base = SurfaceScale(ratio: 1)

    private func scaled(_ valueAtBase: CGFloat) -> CGFloat { valueAtBase * ratio }

    // MARK: Header row (`.hrow`, `.search`)

    /// `.hrow` top padding (10) in the popover.
    var headerTop: CGFloat { scaled(10) }
    /// `.hrow` bottom padding (8).
    var headerBottom: CGFloat { scaled(8) }
    /// `.search`: 28pt tall at 13; the header buttons are centered on it.
    var searchFieldHeight: CGFloat { scaled(28) }
    /// `.hb`: the header buttons (and the pane header's back button), 24pt
    /// square at 13.
    var headerButton: CGFloat { scaled(24) }
    /// `.ic`: their icons, 15pt at 13, and the icons' line widths (1.4; the
    /// pin 1.2; the ⌄ chevron 1.6).
    var headerIcon: CGFloat { scaled(15) }
    var headerIconLine: CGFloat { scaled(1.4) }
    var pinIconLine: CGFloat { scaled(1.2) }
    var menuChevronLine: CGFloat { scaled(1.6) }
    /// `.search` text.
    var searchFieldFont: CGFloat { scaled(12) }
    /// `.search` magnifier and its stroke.
    var searchIcon: CGFloat { scaled(13) }
    var searchIconLine: CGFloat { scaled(1.4) }
    /// `.search .clr`: the clear button's circle.
    var searchClearButton: CGFloat { scaled(12) }

    /// The header row's height: the taller of the search field and the
    /// header buttons.
    var headerRowHeight: CGFloat { max(searchFieldHeight, headerButton) }

    /// The space above and the equal space below a window header whose row
    /// is `contentHeight` tall: the row centered on the traffic lights
    /// (52pt in all) — or, when that leaves less than the minimum, the
    /// minimum on both sides (the header grows; its row sits as close to
    /// the traffic lights' center as it can).
    static func windowHeaderPadding(contentHeight: CGFloat) -> CGFloat {
        max(SurfaceMetrics.windowTrafficLightCenter - contentHeight / 2, SurfaceMetrics.windowHeaderMinimumPadding)
    }

    /// The window's header row: the space above and below it.
    var windowHeaderPadding: CGFloat { Self.windowHeaderPadding(contentHeight: headerRowHeight) }

    // MARK: List

    /// Empty-state and hidden-rows lines.
    var listNoteFont: CGFloat { scaled(12) }
    var emptyStateVertical: CGFloat { scaled(8) }
    var hiddenRowsVertical: CGFloat { scaled(6) }
    /// Below the last row.
    var listBottom: CGFloat { scaled(8) }
    /// Headings (`.rows .sec`): bold name and count. The band is 30pt tall
    /// at 13, its two 1pt lines included; only the part between the lines
    /// follows the text size (§9). The text-and-line headings under History
    /// (`.sec.sub`) are 4 inside at the top and the bottom, with 6 above
    /// and 4 below them. Two neighbors are apart by the larger of the upper
    /// one's space below and the lower one's space above; a frame of rows
    /// has none of its own.
    var sectionTitleFont: CGFloat { scaled(12) }
    var sectionCountFont: CGFloat { scaled(11) }
    var sectionBandContentHeight: CGFloat { scaled(28) }
    var sectionBandHeight: CGFloat { sectionBandContentHeight + 2 * SurfaceMetrics.sectionBandLine }
    var subHeadingTop: CGFloat { scaled(6) }
    var subHeadingBottom: CGFloat { scaled(4) }
    var subHeadingVertical: CGFloat { scaled(4) }
    /// The chevron: a 12pt line-art icon (stroke 1.8) in a 14pt box.
    var sectionChevronBox: CGFloat { scaled(14) }
    var sectionChevronIcon: CGFloat { scaled(12) }
    var sectionChevronLine: CGFloat { scaled(1.8) }
    /// The Running mark's dot (§9: 7pt at 13).
    var runningMark: CGFloat { scaled(7) }
    /// The reason a row cannot be dragged (`.tip`): 12pt text, 4 inside at
    /// the top and the bottom (its sides, corner radius and distance from
    /// the pointer are fixed — `SurfaceMetrics`).
    var refusalTipFont: CGFloat { scaled(12) }
    var refusalTipVertical: CGFloat { scaled(4) }

    // MARK: Row

    /// The symbol-and-time column's smallest width with one symbol box
    /// (§9: 28pt at 13 — Running rows and the Archive view's rows). The
    /// elapsed time widens it when it does not fit (§4.5).
    var rowSymbolColumn: CGFloat { scaled(28) }

    /// The column's smallest width for `boxCount` symbol boxes (§9): one box
    /// takes `rowSymbolColumn`; the normal list's History rows (the star and
    /// the more button) take the two boxes and the fixed 4pt between them —
    /// 44pt at 13.
    func rowSymbolColumnWidth(boxCount: Int) -> CGFloat {
        guard boxCount > 1 else { return rowSymbolColumn }
        return max(rowSymbolColumn,
                   CGFloat(boxCount) * rowSymbol + CGFloat(boxCount - 1) * SurfaceMetrics.rowSymbolBoxSpacing)
    }
    /// The column's symbol box, 20×20 (§9): the status symbol's size, and the
    /// star's click area (§4.6 "stars").
    var rowSymbol: CGFloat { scaled(20) }
    /// The symbol sits 1pt below the row's text top, level with the label
    /// line (the row's top line).
    var rowSymbolTop: CGFloat { scaled(1) }
    /// The History star (§9: 16pt at 13, smaller than the status symbol and
    /// centered in the symbol box) and its strokes.
    var star: CGFloat { scaled(16) }
    /// The more button's three dots (§9: 16pt at 13, centered in the box).
    var moreButtonIcon: CGFloat { scaled(16) }
    var starFilledLine: CGFloat { scaled(0.7) }
    var starOutlineLine: CGFloat { scaled(1.1) }
    /// The row's three lines (§4.5): the label and the last prompt in the
    /// small size, the bold title in the body size. The elapsed time in the
    /// symbol-and-time column uses the label's size.
    var rowTitleFont: CGFloat { scaled(13) }
    var rowLabelFont: CGFloat { scaled(11) }
    var rowPromptFont: CGFloat { scaled(11) }
    /// Between the label and the title (§9: 1pt at 13).
    var rowLabelTitleSpacing: CGFloat { scaled(1) }
    /// Between the title and the last prompt (§9: 4pt at 13), wider than
    /// the label-title gap so the label and the title read as one pair,
    /// apart from the last prompt (§8.59).
    var rowTitlePromptSpacing: CGFloat { scaled(4) }
    /// Line boxes of the row lines: the title inherits `.app` (13px,
    /// line-height 1.35); the label and the last prompt are `.sub` / `.t3`
    /// (11px, line-height 1.45). Text is vertically centered in its box.
    var rowTitleHeight: CGFloat { scaled(17.55) }
    var rowLabelHeight: CGFloat { scaled(15.95) }
    var rowPromptHeight: CGFloat { scaled(15.95) }
    var rowTop: CGFloat { scaled(8) }
    var rowBottom: CGFloat { scaled(9) }

    // MARK: Footer, status lines, key hints

    var statusLineFont: CGFloat { scaled(12) }
    var messageLineFont: CGFloat { scaled(11) }
    var statusLineTop: CGFloat { scaled(7) }
    /// Below the status lines above a one-column bottom panel.
    var panelStatusBottom: CGFloat { scaled(7) }
    var footerHintsTop: CGFloat { scaled(7) }
    var footerHintsBottom: CGFloat { scaled(9) }
    /// `.hints` key chip (10.5 monospaced, 1pt vertical padding) and label.
    var keyChipFont: CGFloat { scaled(10.5) }
    var keyChipVertical: CGFloat { scaled(1) }
    var keyLabelFont: CGFloat { scaled(11) }

    // MARK: Bottom panel (`.actions`, `.btn`)

    var panelTop: CGFloat { scaled(9) }
    var panelBottom: CGFloat { scaled(10) }
    /// Between the disabled-button reason lines and the button row below
    /// them; the lines take `panelTop` above them in place of the row.
    var panelReasonBottom: CGFloat { scaled(4) }
    var panelButtonFont: CGFloat { scaled(13) }
    /// `.btn`: minimum width 84 including its 14pt horizontal paddings.
    var primaryButtonMinWidth: CGFloat { scaled(84) }
    var primaryButtonVertical: CGFloat { scaled(5) }
    var branchButtonVertical: CGFloat { scaled(4) }

    // MARK: Conversation pane header (`.hdr`), find bar, centered lines

    /// `.hdr .ht`: 13.5 on the detail page, 15 in two columns.
    var paneTitleDetailFont: CGFloat { scaled(13.5) }
    var paneTitleColumnFont: CGFloat { scaled(15) }
    var paneLabelFont: CGFloat { scaled(11) }
    var panePositionFont: CGFloat { scaled(11) }
    var paneTitleSpacing: CGFloat { scaled(1) }
    /// `.hdr` top padding 9 (`.hdr.pad` 11 in two columns), bottom 8.
    var paneHeaderTopDetail: CGFloat { scaled(9) }
    var paneHeaderTopColumn: CGFloat { scaled(11) }
    var paneHeaderBottom: CGFloat { scaled(8) }
    /// The title block (the label line + the title) is about 32pt tall at 13.
    var paneTitleBlockHeight: CGFloat { scaled(32) }
    /// The previous / next conversation control: 26×22 segments with 13pt
    /// chevrons.
    var stepperSegmentWidth: CGFloat { scaled(26) }
    var stepperSegmentHeight: CGFloat { scaled(22) }
    var stepperIcon: CGFloat { scaled(13) }
    var stepperIconLine: CGFloat { scaled(1.5) }
    var findBarFont: CGFloat { scaled(11) }
    var findBarVertical: CGFloat { scaled(5) }
    /// A centered line in place of the messages (no selection, no messages,
    /// a load error).
    var centeredLineFont: CGFloat { scaled(12) }

    /// The one-column detail page's header row in the window: the title
    /// block, the back button and the stepper side by side.
    var windowDetailPaneHeaderRowHeight: CGFloat {
        max(paneTitleBlockHeight, headerButton, stepperSegmentHeight)
    }

    /// The space above and below it, by the window header rule. (In two
    /// columns the pane header sits under the window-wide header row and
    /// uses `paneHeaderTopColumn` / `paneHeaderBottom`.)
    var windowDetailPaneHeaderPadding: CGFloat {
        Self.windowHeaderPadding(contentHeight: windowDetailPaneHeaderRowHeight)
    }
}

private struct SurfaceScaleKey: EnvironmentKey {
    static let defaultValue = SurfaceScale.base
}

extension EnvironmentValues {
    /// The popover's and the window's scale (DESIGN.md §4.5 "text size").
    var surfaceScale: SurfaceScale {
        get { self[SurfaceScaleKey.self] }
        set { self[SurfaceScaleKey.self] = newValue }
    }
}

// MARK: - Line-art icons (window-design.html `<symbol>`s, 16-unit box)

enum SurfaceIcon {
    case search, refresh, pin, chevronDown, chevronUp, chevronRight, back, window, popover, star, more

    /// The icon's outline on a 16-unit box, y down.
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        let ox = rect.minX + (rect.width - 16 * s) / 2
        let oy = rect.minY + (rect.height - 16 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func circle(_ path: inout Path, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: ox + (cx - r) * s, y: oy + (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        func roundedRect(_ path: inout Path, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
            path.addRoundedRect(in: CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s),
                                cornerSize: CGSize(width: r * s, height: r * s))
        }
        func polyline(_ path: inout Path, _ points: [(CGFloat, CGFloat)], close: Bool = false) {
            guard let first = points.first else { return }
            path.move(to: p(first.0, first.1))
            for point in points.dropFirst() { path.addLine(to: p(point.0, point.1)) }
            if close { path.closeSubpath() }
        }
        var path = Path()
        switch self {
        case .search:
            circle(&path, 7, 7, 4.5)
            polyline(&path, [(10.5, 10.5), (14, 14)])
        case .refresh:
            // `i-refresh`: an arc of radius 5 around (8, 8), clockwise on
            // screen (y down) from (13, 8) round to (11.5, 4.4), and the
            // arrow head (11.7, 1.9) → (11.7, 4.5) → (9.1, 4.5) at that end.
            let end = atan2(4.4 - 8.0, 11.5 - 8.0) + 2 * Double.pi
            let steps = 48
            for i in 0...steps {
                let angle = Double(i) / Double(steps) * end
                let point = p(8 + 5 * CGFloat(cos(angle)), 8 + 5 * CGFloat(sin(angle)))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            polyline(&path, [(11.7, 1.9), (11.7, 4.5), (9.1, 4.5)])
        case .pin:
            // `i-pin`: a push pin tilted 45°, head at the top right, needle
            // to the bottom left, as one closed outline.
            polyline(&path, [
                (9.5, 1.5), (14.5, 6.5), (13.1, 7.9), (12.4, 7.2), (9.4, 10.2), (9.8, 12.8),
                (8.6, 14), (5.7, 11), (2.5, 14.2), (1.3, 13), (4.5, 9.8), (1.6, 6.9),
                (2.8, 5.7), (5.4, 6.1), (8.4, 3.1), (7.7, 2.4),
            ], close: true)
        case .chevronDown:
            polyline(&path, [(4, 6), (8, 10), (12, 6)])
        case .chevronUp:
            polyline(&path, [(4, 10), (8, 6), (12, 10)])
        case .chevronRight:
            polyline(&path, [(6, 4), (10, 8), (6, 12)])
        case .back:
            polyline(&path, [(10, 3.5), (5.5, 8), (10, 12.5)])
        case .window:
            roundedRect(&path, 2, 3, 12, 10, 2)
            polyline(&path, [(2, 6.2), (14, 6.2)])
        case .popover:
            // `i-popover`: a rounded square with the menu bar line near its
            // top and an upward arrow under it.
            roundedRect(&path, 2, 2.5, 12, 11, 2.2)
            polyline(&path, [(2, 5.6), (14, 5.6)])
            polyline(&path, [(8, 11.6), (8, 8)])
            polyline(&path, [(6.1, 9.7), (8, 7.8), (9.9, 9.7)])
        case .more:
            // `i-more`: three dots side by side, drawn filled.
            for x: CGFloat in [3.5, 8, 12.5] { circle(&path, x, 8, 1.3) }
        case .star:
            polyline(&path, [
                (8, 1.8), (9.9, 5.7), (14.2, 6.3), (11.1, 9.3), (11.8, 13.6),
                (8, 11.6), (4.2, 13.6), (4.9, 9.3), (1.8, 6.3), (6.1, 5.7),
            ], close: true)
        }
        return path
    }
}

/// A stroked line-art icon (`.ic`: 15px, stroke 1.4, round caps / joins, at
/// text size 13; the header buttons pass the scaled `headerIcon` /
/// `headerIconLine`).
struct SurfaceIconView: View {
    let icon: SurfaceIcon
    var size: CGFloat = 15
    var lineWidth: CGFloat = 1.4
    var filled = false

    var body: some View {
        IconShape(icon: icon)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .background(filled ? IconShape(icon: icon).fill() : nil)
            .frame(width: size, height: size)
    }
}

struct IconShape: Shape {
    let icon: SurfaceIcon
    func path(in rect: CGRect) -> Path { icon.path(in: rect) }
}

// MARK: - Button styles

/// `.hb`: no ground at rest, 16% gray on hover, 24% while pressed
/// (window-design.html). `restingOpacity` gives the ⌄ chip its 10% ground.
/// `onTint` is the ground of a button that is ON (`.hb.on`: the pin while
/// Keep on Top is ON — DESIGN.md §4.5 "pin"): the tint at 16%, 24% while
/// pressed, in the same shape as the hover ground.
struct HoverChipButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    var restingOpacity: Double = 0
    var isEnabled = true
    var onTint: Color?

    func makeBody(configuration: Configuration) -> some View {
        HoverChipBody(configuration: configuration, cornerRadius: cornerRadius,
                      restingOpacity: restingOpacity, isEnabled: isEnabled, onTint: onTint)
    }

    private struct HoverChipBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let restingOpacity: Double
        let isEnabled: Bool
        let onTint: Color?
        @State private var hovering = false

        private var ground: Color {
            if let onTint {
                return onTint.opacity(configuration.isPressed ? 0.24 : 0.16)
            }
            let opacity: Double = !isEnabled ? restingOpacity
                : configuration.isPressed ? 0.24
                : hovering ? 0.16
                : restingOpacity
            return Color.gray.opacity(opacity)
        }

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: cornerRadius).fill(ground))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// The ⌄ menu anchor: hands an `NSView` to SwiftUI so `NSMenu.popUp` has a
/// host view.
struct MenuAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> MenuAnchorNSView {
        let view = MenuAnchorNSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: MenuAnchorNSView, context: Context) {}
}

/// The ⌄ button's anchor view: it takes the button's frame, so the menu
/// opens under the button (and tests can find the button's place).
final class MenuAnchorNSView: NSView {}

/// Lets the empty parts of a header row drag the window (§4.5: the window
/// has no visible title bar; the header row's empty area moves it). A
/// double click zooms, like a title bar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
