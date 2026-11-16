// Colors, metrics and line-art icons for the popover and the window
// (visual spec: docs/window-design.html). The CSS values there are paper
// examples for colors — the implementation follows the system colors and
// the accent color (window-design.html "implementation notes"); the star
// yellow and the unreviewed red use the page's values. Sizes and spacing
// follow the mock's CSS.

import AppKit
import SwiftUI

enum SurfaceColors {
    /// The list's pale, opaque ground in the popover and the window: a
    /// shade off the system backgrounds so white cards stand out on light
    /// and veiled cards on dark (window-design.html `--cardsbg`). The
    /// popover paints its arrow with the same color.
    static let listBackgroundNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: .black) ?? .windowBackgroundColor
            : NSColor.controlBackgroundColor.blended(withFraction: lightListGrayFraction, of: .systemGray)
                ?? .windowBackgroundColor
    }
    /// The share of gray in the light list ground: enough that the ground is
    /// visibly off the white cards.
    static let lightListGrayFraction: CGFloat = 0.10
    static let listBackground = Color(nsColor: listBackgroundNSColor)
    /// The conversation pane: the plain reading background.
    static let paneBackground = Color(nsColor: .controlBackgroundColor)
    /// A card: opaque white on light; a light veil on dark so it reads on
    /// any ground (window background or popover material).
    static let cardNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.controlBackgroundColor
    }
    static let card = Color(nsColor: cardNSColor)
    static let cardBorderNSColor = NSColor.separatorColor
    static let cardBorder = Color(nsColor: cardBorderNSColor)
    /// Selected card ground while the list has focus: a pale accent tint
    /// (window-design.html `.sel`; DESIGN.md §4.5 "row selection").
    static let selectionTint = Color.accentColor.opacity(0.16)
    /// Selected card border while the list has focus, and the hovered card
    /// border (`--tintline`).
    static let tintLine = Color.accentColor.opacity(0.5)
    /// Selected card ground while the search field has focus: a pale neutral
    /// gray, the inactive-selection look (window-design.html `.sel.inact`).
    /// Slightly denser on dark, where the veiled cards are close in value.
    static let inactiveSelectionTint = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor.systemGray.withAlphaComponent(
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.26 : 0.18)
    })
    /// Selected card border while the search field has focus (`--grayline`):
    /// clearly stronger than the unselected border, and not the accent the
    /// hovered border uses.
    static let inactiveSelectionLine = Color(nsColor: .systemGray).opacity(0.6)
    static let line = Color(nsColor: .separatorColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    /// Neutral chip / key-hint ground (`rgba(127,127,127,.09)`).
    static let chip = Color.gray.opacity(0.09)
    /// §8.49: yellow is for stars only (page values).
    static let starFill = Color(red: 0xF5 / 255, green: 0xB4 / 255, blue: 0x00 / 255)
    static let starLine = Color(red: 0xD3 / 255, green: 0x97 / 255, blue: 0x00 / 255)
}

/// Dimensions that do not follow the text size (DESIGN.md §4.5 "text size":
/// horizontal paddings and gaps, corner radii, border widths, the header
/// row's buttons and their icons, and parts the OS draws).
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
    /// `.hb`: 24×24, radius 7.
    static let headerButton: CGFloat = 24
}

/// Dimensions that follow the text size (DESIGN.md §4.5 "text size"): each
/// property is its window-design.html value at text size 13 times `ratio`.
/// Font sizes, row heights, vertical paddings and gaps, icons and symbols,
/// the search field height and the primary button's minimum width. Views
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
    /// `.search`: 24pt tall at 13, level with the 24pt header buttons.
    var searchFieldHeight: CGFloat { scaled(24) }
    /// `.search` text.
    var searchFieldFont: CGFloat { scaled(12) }
    /// `.search` magnifier and its stroke.
    var searchIcon: CGFloat { scaled(13) }
    var searchIconLine: CGFloat { scaled(1.4) }
    /// `.search .clr`: the clear button's circle.
    var searchClearButton: CGFloat { scaled(12) }

    /// The header row's height: the taller of the search field and the
    /// fixed header buttons.
    var headerRowHeight: CGFloat { max(searchFieldHeight, SurfaceMetrics.headerButton) }

    /// The header row's top padding in the window: its vertical center on
    /// the traffic lights' center.
    var windowHeaderTop: CGFloat {
        SurfaceMetrics.windowTrafficLightCenter - headerRowHeight / 2
    }

    // MARK: List

    /// Empty-state and hidden-rows lines.
    var listNoteFont: CGFloat { scaled(12) }
    var emptyStateVertical: CGFloat { scaled(8) }
    var hiddenRowsVertical: CGFloat { scaled(6) }
    /// Below the last row.
    var listBottom: CGFloat { scaled(8) }
    /// Between cards.
    var rowGap: CGFloat { scaled(6) }
    /// Section header: bold name and count, top 10 / bottom 6.
    var sectionTitleFont: CGFloat { scaled(12) }
    var sectionCountFont: CGFloat { scaled(11) }
    var sectionHeaderTop: CGFloat { scaled(10) }
    var sectionHeaderBottom: CGFloat { scaled(6) }

    // MARK: Row card

    /// The leading slot (status symbol or star), 20×20.
    var rowLeadingSlot: CGFloat { scaled(20) }
    /// The slot sits 1pt below the card's text top.
    var rowLeadingSlotTop: CGFloat { scaled(1) }
    /// The History star and its strokes.
    var star: CGFloat { scaled(16) }
    var starFilledLine: CGFloat { scaled(0.7) }
    var starOutlineLine: CGFloat { scaled(1.1) }
    var rowLine1Font: CGFloat { scaled(13) }
    var rowLine2Font: CGFloat { scaled(11) }
    var rowPromptFont: CGFloat { scaled(11) }
    var rowLineSpacing: CGFloat { scaled(1) }
    var rowCardTop: CGFloat { scaled(8) }
    var rowCardBottom: CGFloat { scaled(9) }
    /// `.ib` (the row's `>` button): 28×26 with a 15pt chevron.
    var rowOpenButtonWidth: CGFloat { scaled(28) }
    var rowOpenButtonHeight: CGFloat { scaled(26) }
    var rowOpenIcon: CGFloat { scaled(15) }
    var rowOpenIconLine: CGFloat { scaled(1.4) }

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
    var panelButtonFont: CGFloat { scaled(13) }
    /// `.btn`: minimum width 84 including its 14pt horizontal paddings.
    var primaryButtonMinWidth: CGFloat { scaled(84) }
    var primaryButtonVertical: CGFloat { scaled(5) }
    var branchButtonVertical: CGFloat { scaled(4) }

    // MARK: Conversation pane header (`.hdr`), find bar, centered lines

    /// `.hdr .ht`: 13.5 on the detail page, 15 in two columns.
    var paneTitleDetailFont: CGFloat { scaled(13.5) }
    var paneTitleColumnFont: CGFloat { scaled(15) }
    var paneSubtitleFont: CGFloat { scaled(11) }
    var panePositionFont: CGFloat { scaled(11) }
    var paneTitleSpacing: CGFloat { scaled(1) }
    /// `.hdr` top padding 9 (`.hdr.pad` 11 in two columns), bottom 8.
    var paneHeaderTopDetail: CGFloat { scaled(9) }
    var paneHeaderTopColumn: CGFloat { scaled(11) }
    var paneHeaderBottom: CGFloat { scaled(8) }
    /// The title block (title + subtitle) is about 32pt tall at 13.
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

    /// The pane header's top padding in the window. The one-column detail
    /// page centers its row on the traffic lights; in two columns the right
    /// column's header keeps the center it has at 13 (`.hdr.pad` 11 over a
    /// 32pt title block), so it stays level with the list column's header
    /// row at any text size.
    func windowPaneHeaderTop(isDetailPage: Bool) -> CGFloat {
        if isDetailPage {
            let rowHeight = max(paneTitleBlockHeight, SurfaceMetrics.headerButton, stepperSegmentHeight)
            return SurfaceMetrics.windowTrafficLightCenter - rowHeight / 2
        }
        let base = SurfaceScale.base
        let centerAtBase = base.paneHeaderTopColumn + base.paneTitleBlockHeight / 2
        return centerAtBase - paneTitleBlockHeight / 2
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
    case search, refresh, pin, chevronDown, chevronUp, chevronRight, back, window, star

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
            // Arc around (8,8), r 5, from 0° clockwise to 315° (y down).
            let steps = 48
            for i in 0...steps {
                let angle = (Double(i) / Double(steps)) * 315.0 * Double.pi / 180
                let point = p(8 + 5 * CGFloat(cos(angle)), 8 + 5 * CGFloat(sin(angle)))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            polyline(&path, [(13, 3), (13, 6), (10, 6)])
        case .pin:
            polyline(&path, [(6, 2), (10, 2), (9.5, 6), (12, 8.5), (4, 8.5), (6.5, 6)], close: true)
            polyline(&path, [(8, 8.5), (8, 14)])
        case .chevronDown:
            polyline(&path, [(4, 6), (8, 10), (12, 6)])
        case .chevronUp:
            polyline(&path, [(4, 10), (8, 6), (12, 10)])
        case .chevronRight:
            polyline(&path, [(6, 3.5), (10.5, 8), (6, 12.5)])
        case .back:
            polyline(&path, [(10, 3.5), (5.5, 8), (10, 12.5)])
        case .window:
            roundedRect(&path, 2, 3, 12, 10, 2)
            polyline(&path, [(2, 6.2), (14, 6.2)])
        case .star:
            polyline(&path, [
                (8, 1.8), (9.9, 5.7), (14.2, 6.3), (11.1, 9.3), (11.8, 13.6),
                (8, 11.6), (4.2, 13.6), (4.9, 9.3), (1.8, 6.3), (6.1, 5.7),
            ], close: true)
        }
        return path
    }
}

/// A stroked line-art icon (`.ic`: 15px, stroke 1.4, round caps / joins).
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

/// `.hb` / `.ib`: no ground at rest, 16% gray on hover, 24% while pressed
/// (window-design.html). `restingOpacity` gives the ⌄ chip its 10% ground.
struct HoverChipButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    var restingOpacity: Double = 0
    var isEnabled = true

    func makeBody(configuration: Configuration) -> some View {
        HoverChipBody(configuration: configuration, cornerRadius: cornerRadius,
                      restingOpacity: restingOpacity, isEnabled: isEnabled)
    }

    private struct HoverChipBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let restingOpacity: Double
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            let opacity: Double = !isEnabled ? restingOpacity
                : configuration.isPressed ? 0.24
                : hovering ? 0.16
                : restingOpacity
            configuration.label
                .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.gray.opacity(opacity)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// The ⌄ menu anchor: hands an `NSView` to SwiftUI so `NSMenu.popUp` has a
/// host view.
struct MenuAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

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
