// Dropdown panel horizontal placement (DESIGN.md §4.5 "panel placement", M29):
// while the icon-anchored, extending-right placement fits the display, the
// OS placement is left untouched; when the icon sits near the display's
// right edge, the panel must NOT flip to extend left from the icon —
// instead the whole panel shifts left so its right edge sits flush with
// the display's visible area (the same edge behavior NSMenu has). This
// type holds the view-free arithmetic; reading the icon/panel windows and
// applying the origin lives in `AppState`.

import Foundation

public enum DropdownPanelPlacement {
    /// Differences at or below this are the OS's own placement — leave it
    /// alone (measured on-device: the normal-case placement is EXACTLY
    /// `icon.minX`, delta 0.0, so the tolerance only needs to absorb
    /// float noise).
    public static let tolerance: Double = 0.5

    /// Desired panel `minX` (§4.5): anchored to the icon's left edge, but
    /// never extending past the visible area's right edge — and never
    /// starting left of the visible area on a pathologically narrow
    /// display (the left clamp wins over the icon anchor).
    public static func clampedX(
        iconMinX: Double,
        panelWidth: Double,
        visibleMinX: Double,
        visibleMaxX: Double
    ) -> Double {
        max(visibleMinX, min(iconMinX, visibleMaxX - panelWidth))
    }
}
