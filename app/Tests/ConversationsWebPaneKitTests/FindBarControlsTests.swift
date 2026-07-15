import AppKit
import XCTest
@testable import ConversationsWebPaneKit

/// The find bar's segmented control sizing (§8.38(8)): it stretched across
/// the whole pane in the owner's build. The control must report a small
/// finite content size (what SwiftUI's .fixedSize pins to) and must resist
/// stretching at the AppKit level too.
final class FindBarControlsTests: XCTestCase {
    @MainActor
    func testSegmentedControlIsContentSized() {
        let control = FindBarControls.makeSegmentedControl(target: nil, action: nil)
        let fitting = control.fittingSize
        XCTAssertGreaterThan(fitting.width, 0)
        XCTAssertLessThan(fitting.width, 100, "two small chevron segments must stay compact, got \(fitting.width)")
        XCTAssertEqual(control.segmentCount, 2)
        XCTAssertEqual(control.trackingMode, .momentary)
        XCTAssertEqual(control.contentHuggingPriority(for: .horizontal), .required,
                       "hugging must be required so nothing stretches it")
    }

    @MainActor
    func testSegmentedControlKeepsItsContentSizeInsideAWideContainer() {
        // The AppKit-level equivalent of "must not stretch across the bar":
        // under Auto Layout in an 800pt container, the control's required
        // hugging keeps it at its fitting width.
        let control = FindBarControls.makeSegmentedControl(target: nil, action: nil)
        control.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            // A weak pull toward the full width — hugging must win.
            {
                let pull = control.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                pull.priority = .defaultLow
                return pull
            }(),
        ])
        container.layoutSubtreeIfNeeded()
        XCTAssertLessThan(control.frame.width, 100,
                          "required hugging must beat the stretch pull, got \(control.frame.width)")
    }

    @MainActor
    func testSegmentTooltips() {
        let control = FindBarControls.makeSegmentedControl(target: nil, action: nil)
        XCTAssertEqual(control.toolTip(forSegment: 0), "Previous match")
        XCTAssertEqual(control.toolTip(forSegment: 1), "Next match")
    }
}
