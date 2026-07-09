// Height rules for the two agent-list containers (DESIGN.md §4.5/§8.32,
// M29): the transient container (dropdown) is sized by its CONTENT, capped
// so the whole dropdown fits the display's visible area; the resident
// container (Agents window) is sized by the USER — vertically resizable,
// height remembered. This type holds the view-free arithmetic so it can be
// unit-tested; reading screens/windows and applying frames stays in the
// app layer (AgentListView / AgentsWindowView / VMenuHandler).

import Foundation

public enum AgentListHeights {
    // MARK: Dropdown (§4.5: content decides, display caps)

    /// Small gap kept between the dropdown's bottom edge and the visible
    /// area's bottom (§4.5's "small margin"; the M29 brief's on-device range is
    /// 8–16pt). Also absorbs the few points of panel chrome the chrome
    /// estimate doesn't model exactly (e.g. the menu-bar-to-panel gap).
    public static let dropdownBottomMargin: Double = 12

    /// The cap never drops below roughly one row (a pathological display
    /// setup must not collapse the list to zero).
    public static let dropdownListCapFloor: Double = 47

    /// Max height for the dropdown's scrolling list (§4.5/§8.32): the
    /// display's `visibleFrame` height (menu bar and Dock excluded) minus
    /// the dropdown's own chrome around the list (topbar, warning rows,
    /// paddings — estimated by the view, which owns those constants) minus
    /// the bottom margin, so the WHOLE dropdown fits the visible area.
    /// Below the cap the list stays content-sized (the cap is a maxHeight,
    /// not a height).
    public static func dropdownListCap(visibleFrameHeight: Double, chromeHeight: Double) -> Double {
        max(dropdownListCapFloor, visibleFrameHeight - chromeHeight - dropdownBottomMargin)
    }

    /// The panel content height the whole dropdown should occupy (M29
    /// panel-height bugfix): the list at its natural (measured) height,
    /// capped by `dropdownListCap`, plus the chrome around it. `AppState`
    /// enforces this on the panel WINDOW because SwiftUI's own MenuBarExtra
    /// sizing clamps the panel to roughly a third of the display's visible
    /// height (measured on-device: 342pt on a 1025pt visible frame, for
    /// any content ideal above it) — a limit a direct window resize lifts
    /// cleanly (the content re-lays out to fill, and later content churn
    /// does not snap it back; measured).
    public static func dropdownPanelContentHeight(
        naturalListHeight: Double,
        listCap: Double,
        chromeHeight: Double
    ) -> Double {
        min(naturalListHeight, listCap) + chromeHeight
    }

    // MARK: Agents window (§4.5: the user decides, height remembered)

    /// Minimum height of the window's CONTENT area (excluding the
    /// traffic-light band, which AppKit adds on top of this in the
    /// window's own minimum): roughly three rows (~47pt each) plus the
    /// list's vertical padding (§4.5: minimum of roughly three rows plus the band).
    public static let agentsWindowMinContentHeight: Double = 150

    /// The frame height to apply when the Agents window opens (§4.5):
    /// the remembered height if one exists (`stored` > 0), otherwise the
    /// first-open fallback (the dropdown panel's own frame height — the
    /// same list content laid out naturally, so the window opens as a
    /// true "pinned dropdown"), clamped to the window's minimum and the
    /// display's visible height. When `maximum < minimum` (a display
    /// smaller than the window's minimum) fitting the display wins.
    public static func agentsWindowHeightToApply(
        stored: Double,
        firstOpenFallback: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        let desired = stored > 0 ? stored : firstOpenFallback
        return min(max(desired, minimum), maximum)
    }
}
