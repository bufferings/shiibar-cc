// Dropdown panel (DESIGN.md §4.5/§8.25): the MenuBarExtra window-style
// panel that opens on a tray click. Its content — TopBar / the list / "No
// agents" / warning rows — is entirely shared with the Open-as-Window
// `Agents` window via `AgentListView` (M26 T1); this file supplies only the
// dropdown's own container context (elapsed-time base and active flag,
// both from `AppState`) and the per-open capture trigger.

import ShiibarCcCore
import SwiftUI

struct DropdownView: View {
    @ObservedObject var state: AppState

    var body: some View {
        AgentListView(
            state: state,
            container: AgentListContainer(
                kind: .dropdown,
                openedAt: state.dropdownOpenedAt,
                isActive: state.isDropdownOpen
            )
        )
        // Belt and braces for the per-open capture: the primary signal is
        // NSWindow.didBecomeKeyNotification (see AppState.observeDropdownOpen
        // — the hosted view stays alive across open/close, so onAppear may
        // fire only once at launch). If some macOS version does remount the
        // view per open, both triggers land on the same second — harmless.
        .onAppear { state.captureDropdownOpenTime() }
    }
}
