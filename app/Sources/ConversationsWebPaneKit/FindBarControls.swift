// The find bar's back/forward segmented control (DESIGN.md §4.6/§8.38(8)):
// a native momentary NSSegmentedControl, CONTENT-SIZED — the round-5 owner
// build had it stretched across the whole pane because the SwiftUI host let
// it take the full width proposal. The factory lives in this (AppKit-linked,
// testable) kit so its sizing is pinned by a test; the SwiftUI side must
// additionally wrap it in .fixedSize() so the intrinsic size is what lays
// out.

import AppKit

public enum FindBarControls {
    /// The ‹ › control: momentary tracking, small size, per-segment
    /// tooltips, and required content hugging so it never stretches.
    public static func makeSegmentedControl(target: AnyObject?, action: Selector?) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: ["\u{2039}", "\u{203A}"], // single guillemets: previous / next
            trackingMode: .momentary,
            target: target,
            action: action
        )
        control.controlSize = .small
        control.segmentDistribution = .fit
        control.setToolTip("Previous match", forSegment: 0)
        control.setToolTip("Next match", forSegment: 1)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }
}
