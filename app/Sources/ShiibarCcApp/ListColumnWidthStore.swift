// The remembered two-column list column width and the boundary drag in
// progress (DESIGN.md §4.5 "column boundary drag", §8.53, §9). The width
// arithmetic and the stored-value interpretation live in
// ShiibarCcCore.ListColumnWidth; this object owns the UserDefaults IO and
// publishes what the window's two-column layout shows.

import Combine
import Foundation
import ShiibarCcCore
import SwiftUI

@MainActor
final class ListColumnWidthStore: ObservableObject {
    /// The remembered width, or nil while the column follows the text size.
    /// Kept as stored: clamping to the window happens at display time only.
    @Published private(set) var remembered: Double?
    /// The drag in progress, if any; its width is shown while it lasts.
    @Published private(set) var drag: ListColumnWidthDrag?

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Interpreted, never rewritten here.
        self.remembered = ListColumnWidth.fromStored(defaults.object(forKey: MainSurfaceDefaultsKeys.listColumnWidth))
    }

    /// The list column width to show for a window content width. A drag's
    /// width is clamped again here, so the right column keeps its minimum
    /// when the window width changes without a pointer move.
    func shownWidth(windowWidth: Double, textSize: TextSize) -> Double {
        if let drag { return ListColumnWidth.clamp(drag.width, windowWidth: windowWidth) }
        return ListColumnWidth.shown(remembered: remembered, windowWidth: windowWidth, textSize: textSize)
    }

    /// Mouse-down on the boundary: the drag starts from the width shown now.
    func beginDrag(windowWidth: Double, textSize: TextSize) {
        drag = ListColumnWidthDrag(startWidth: shownWidth(windowWidth: windowWidth, textSize: textSize))
    }

    /// Every drag event: the horizontal travel since mouse-down in screen
    /// coordinates, and the window content width of that moment. The width
    /// follows without an animation (§4.5).
    func updateDrag(delta: Double, windowWidth: Double) {
        guard var next = drag else { return }
        next.update(dragDelta: delta, windowWidth: windowWidth)
        guard next != drag else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag = next }
    }

    /// Mouse-up: the width is remembered only when the drag changed it, so a
    /// plain click keeps both the stored value and the text-size link.
    func endDrag() {
        guard let finished = drag else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let width = finished.widthToPersist {
                remembered = width
                defaults.set(width, forKey: MainSurfaceDefaultsKeys.listColumnWidth)
            }
            drag = nil
        }
    }

    /// The layout left two columns during a drag (a text size change, for
    /// example), or the window or the drag area went away: the drag ends and
    /// nothing is remembered (§4.5).
    func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
    }

    /// Double-click on the boundary: erase the remembered width; the column
    /// returns to the default width, without an animation, and follows the
    /// text size again. With nothing remembered, nothing happens.
    func resetToDefault() {
        guard remembered != nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drag = nil
            remembered = nil
        }
        defaults.removeObject(forKey: MainSurfaceDefaultsKeys.listColumnWidth)
    }
}
