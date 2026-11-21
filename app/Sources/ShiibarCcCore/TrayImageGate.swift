/// A dot color resolved to concrete sRGB components (0...1). The tray
/// resolves `systemOrange` / `controlAccentColor` against the status item
/// button's appearance before it draws, and the same value is both drawn and
/// compared here (DESIGN.md §4.5 "visual source of truth": resolving at
/// drawing time could draw a color other than the one compared).
public struct ResolvedRGBA: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Decides whether the tray image must be re-rendered and assigned.
///
/// The tray image depends only on the `TrayIconState`, whether the menu bar
/// is dark, and the resolved color of the corner dot, so a new image is
/// needed only when one of those changes. Assigning the status item
/// button's image unconditionally loops: setting the image schedules a
/// replicant redraw, the redraw sets the button's appearance, which
/// re-fires the `effectiveAppearance` observation that refreshes the image
/// again (DESIGN.md §4.5, §8.51).
public struct TrayImageGate: Sendable {
    private struct Inputs: Equatable {
        let state: TrayIconState
        let darkMenuBar: Bool
        let dotColor: ResolvedRGBA?
    }

    private var lastRendered: Inputs?

    public init() {}

    /// Returns true when the image for these inputs must be rendered: on the
    /// first call, and whenever any input differs from the last call that
    /// returned true. Returns false when nothing the image depicts changed.
    /// `dotColor` is the dot's resolved color (nil when there is no dot).
    public mutating func shouldRender(state: TrayIconState, darkMenuBar: Bool, dotColor: ResolvedRGBA?) -> Bool {
        let inputs = Inputs(state: state, darkMenuBar: darkMenuBar, dotColor: dotColor)
        if inputs == lastRendered { return false }
        lastRendered = inputs
        return true
    }
}
