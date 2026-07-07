// Settings window (DESIGN.md §4.5 "Settings window" / §8.26/§8.27):
// opened from the ⌄ menu's "Settings…" item (replacing the old Settings
// submenu, M14 T1). Independent window, `NSApp.activate` on appear (same
// LSUIElement requirement as Setup Check), no in-content close button — the
// title bar's red button / ⌘W is the only way to close, because every
// control here applies immediately (no "OK to confirm"). Two groups:
// General (Start at Login, reusing AppState's existing SMAppService
// read/write) and Sounds (Mute sound / Waiting sound / Done sound, Waiting
// above Done per the product's own waiting > working > idle priority).
// Values are all UserDefaults-backed via `NotificationManager` (§4.5) — this
// view only wires them to SwiftUI and previews a pick via `NSSound(named:)`
// (direct playback, not through a notification — the pick is a user-
// initiated action, not an event, §4.5).

import AppKit
import ShiibarCcCore
import SwiftUI

/// Owns the Settings window's editable state. `@MainActor` because it drives
/// SwiftUI and touches `NotificationManager` (itself `@MainActor`).
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var loginItemEnabled: Bool
    @Published var muted: Bool
    @Published var waitingSoundName: String
    @Published var doneSoundName: String
    let availableSoundNames: [String]

    private let notificationManager: NotificationManager
    private let loginItemEnabledProvider: () -> Bool
    private let toggleLoginItemAction: () -> Void

    init(
        notificationManager: NotificationManager,
        loginItemEnabledProvider: @escaping () -> Bool,
        toggleLoginItem: @escaping () -> Void,
        availableSoundNames: [String] = SoundEnumerator.availableSoundNames()
    ) {
        self.notificationManager = notificationManager
        self.loginItemEnabledProvider = loginItemEnabledProvider
        self.toggleLoginItemAction = toggleLoginItem
        self.loginItemEnabled = loginItemEnabledProvider()
        self.muted = notificationManager.isMuted
        self.waitingSoundName = notificationManager.waitingSoundName
        self.doneSoundName = notificationManager.doneSoundName
        self.availableSoundNames = availableSoundNames
    }

    /// Re-reads `SMAppService.mainApp.status` (never cached, same rule as
    /// the old ⌄-menu checkmark — DESIGN.md §4.5) so the window can't drift
    /// from System Settings' own Login Items UI.
    func refreshLoginItemStatus() {
        loginItemEnabled = loginItemEnabledProvider()
    }

    func toggleLoginItem() {
        toggleLoginItemAction()
        refreshLoginItemStatus()
    }

    func setMuted(_ value: Bool) {
        muted = value
        notificationManager.isMuted = value
    }

    /// DESIGN.md §4.5: the moment a sound is selected, play it once via
    /// `NSSound(named:)` — preview plays immediately on selection, independent of
    /// whether Mute sound is on (the picker itself is disabled while muted,
    /// so this path is only reachable when it isn't).
    func setWaitingSoundName(_ value: String) {
        waitingSoundName = value
        notificationManager.waitingSoundName = value
        NSSound(named: value)?.play()
    }

    func setDoneSoundName(_ value: String) {
        doneSoundName = value
        notificationManager.doneSoundName = value
        NSSound(named: value)?.play()
    }
}

struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel

    init(
        notificationManager: NotificationManager,
        loginItemEnabledProvider: @escaping () -> Bool,
        toggleLoginItem: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(
            notificationManager: notificationManager,
            loginItemEnabledProvider: loginItemEnabledProvider,
            toggleLoginItem: toggleLoginItem
        ))
    }

    var body: some View {
        // A grouped `Form` (DESIGN.md §4.5: the look is a SwiftUI Form +
        // .formStyle(.grouped)) — macOS renders native switch toggles,
        // boxed sections, and row separators (the System Settings look), so
        // the section headers and dividers come from the form chrome rather
        // than being drawn by hand. The window's own title bar already reads
        // as a settings pane, so no in-content "Settings" heading is drawn
        // (a grouped Form with a redundant title looks doubled-up).
        Form {
            Section("General") {
                Toggle("Start at Login", isOn: Binding(
                    get: { viewModel.loginItemEnabled },
                    set: { _ in viewModel.toggleLoginItem() }
                ))
            }

            Section("Sounds") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Mute sound", isOn: Binding(
                        get: { viewModel.muted },
                        set: { viewModel.setMuted($0) }
                    ))
                    Text("Notifications arrive silently")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // Waiting above Done (§4.5: matches the product's own
                // priority order, waiting > working > idle).
                Picker("Waiting sound", selection: Binding(
                    get: { viewModel.waitingSoundName },
                    set: { viewModel.setWaitingSoundName($0) }
                )) {
                    ForEach(viewModel.availableSoundNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(viewModel.muted)

                Picker("Done sound", selection: Binding(
                    get: { viewModel.doneSoundName },
                    set: { viewModel.setDoneSoundName($0) }
                )) {
                    ForEach(viewModel.availableSoundNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(viewModel.muted)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // `NSApp.activate` is required in an LSUIElement (accessory)
            // app, same as Setup Check (§4.5).
            NSApp.activate(ignoringOtherApps: true)
            viewModel.refreshLoginItemStatus()
        }
    }
}
