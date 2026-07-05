// Tray icon label for the MenuBarExtra: a single `Image(nsImage:)` produced
// by `TrayIconRenderer`. Composed SwiftUI views do NOT render reliably in a
// MenuBarExtra label (on-device, Shape strokes were dropped and the text
// layout was flattened to a bare menu-bar-styled ❯), so everything —
// window frame, prompt, status character, red dot, dim level — is baked
// into the image, per DESIGN.md §4.5's NSImage-compositing instruction.
// See TrayIconRenderer for the template/non-template two-layer rule and
// the tunable geometry constants.
//
// `colorScheme` reflects the menu bar appearance the label is hosted in;
// it only matters for the non-template (red dot) variant, whose glyph
// monochrome must be picked manually since a non-template image doesn't
// auto-tint.
//
// This view observes AppState directly (rather than taking a TrayIconState
// value): a MenuBarExtra label is only re-evaluated when something a view
// inside it observes changes, so a value snapshot passed in from the label
// closure would freeze the tray at its launch-time rendering (seen
// on-device).

import ShiibarCcCore
import SwiftUI

struct TrayIconView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: TrayIconRenderer.render(state: state.trayIcon, darkMenuBar: colorScheme == .dark))
    }
}
