/// Decides whether the tray image must be re-rendered and assigned.
///
/// The tray image depends only on the `TrayIconState` and whether the menu
/// bar is dark, so a new image is needed only when that pair changes.
/// Assigning the status item button's image unconditionally loops: setting
/// the image schedules a replicant redraw, the redraw sets the button's
/// appearance, which re-fires the `effectiveAppearance` observation that
/// refreshes the image again.
public struct TrayImageGate: Sendable {
    private var lastRendered: (state: TrayIconState, darkMenuBar: Bool)?

    public init() {}

    /// Returns true when the image for these inputs must be rendered: on the
    /// first call, and whenever either input differs from the last call that
    /// returned true. Returns false when nothing the image depicts changed.
    public mutating func shouldRender(state: TrayIconState, darkMenuBar: Bool) -> Bool {
        if let last = lastRendered, last.state == state, last.darkMenuBar == darkMenuBar {
            return false
        }
        lastRendered = (state, darkMenuBar)
        return true
    }
}
