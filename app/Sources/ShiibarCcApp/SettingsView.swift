// Settings window (DESIGN.md §4.5 "Settings window" / §8.26/§8.27):
// opened from the ⌄ menu's "Settings…" item (replacing the old Settings
// submenu, M14 T1). Independent window, `NSApp.activate` on appear (same
// LSUIElement requirement as Setup Check), no in-content close button — the
// title bar's red button / ⌘W is the only way to close, because every
// control here applies immediately (no "OK to confirm"). Two groups:
// General (Start at Login, reusing AppState's existing SMAppService
// read/write; Appearance = System / Light / Dark, §8.30/M27 T5) and Sounds
// (Mute sound / Waiting sound / Done sound, Waiting above Done per the
// product's own waiting > working > idle priority), and Conversations
// (Text size popup — §4.5/§4.6, the same live value the Conversations
// window's cmd-plus / cmd-minus / cmd-0 shortcuts read and write, via the
// shared `ConversationsTextSizeStore`).
// Values are all UserDefaults-backed via `NotificationManager` (§4.5) or the
// text-size store — this view only wires them to SwiftUI and previews a
// sound pick via `NSSound(named:)` (direct playback, not through a
// notification — the pick is a user-initiated action, not an event, §4.5).

import AppKit
import ShiibarCcCore
import SwiftUI

/// Owns the Settings window's editable state. `@MainActor` because it drives
/// SwiftUI and touches `NotificationManager` (itself `@MainActor`).
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var loginItemEnabled: Bool
    @Published private(set) var appearance: AppearanceSetting
    @Published var muted: Bool
    @Published var waitingSoundName: String
    @Published var doneSoundName: String
    let availableSoundNames: [String]

    private let notificationManager: NotificationManager
    private let loginItemEnabledProvider: () -> Bool
    private let toggleLoginItemAction: () -> Void
    private let setAppearanceAction: (AppearanceSetting) -> Void

    init(
        notificationManager: NotificationManager,
        loginItemEnabledProvider: @escaping () -> Bool,
        toggleLoginItem: @escaping () -> Void,
        appearanceSetting: AppearanceSetting,
        setAppearance: @escaping (AppearanceSetting) -> Void,
        availableSoundNames: [String] = SoundEnumerator.availableSoundNames()
    ) {
        self.notificationManager = notificationManager
        self.loginItemEnabledProvider = loginItemEnabledProvider
        self.toggleLoginItemAction = toggleLoginItem
        self.appearance = appearanceSetting
        self.setAppearanceAction = setAppearance
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

    /// Appearance pick (§4.5/§8.30, M27 T5): applies the moment it's
    /// selected — `AppState.setAppearanceSetting` flips `NSApp.appearance`
    /// and persists the choice.
    func setAppearance(_ setting: AppearanceSetting) {
        appearance = setting
        setAppearanceAction(setting)
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
    /// The shared Conversations body-size store (§4.5/§4.6): observed
    /// directly (not snapshotted into the view model) so a cmd-shortcut
    /// change from the Conversations window moves this stepper live.
    @ObservedObject private var conversationsTextSize: ConversationsTextSizeStore

    init(
        notificationManager: NotificationManager,
        loginItemEnabledProvider: @escaping () -> Bool,
        toggleLoginItem: @escaping () -> Void,
        appearanceSetting: AppearanceSetting,
        setAppearance: @escaping (AppearanceSetting) -> Void,
        conversationsTextSize: ConversationsTextSizeStore
    ) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(
            notificationManager: notificationManager,
            loginItemEnabledProvider: loginItemEnabledProvider,
            toggleLoginItem: toggleLoginItem,
            appearanceSetting: appearanceSetting,
            setAppearance: setAppearance
        ))
        self.conversationsTextSize = conversationsTextSize
    }

    /// The §9 body-size range (10-20pt) enumerated in one-point steps for the
    /// Text size popup.
    private var textSizeOptions: [Double] {
        Array(stride(
            from: ConversationsTextSize.minimum,
            through: ConversationsTextSize.maximum,
            by: ConversationsTextSize.step
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

                // Appearance (§4.5/§8.30, M27 T5): System / Light / Dark,
                // default System — the OS can stay light while this app
                // (the always-visible Agents window in particular) goes
                // dark. Applies on pick, like every control here.
                Picker("Appearance", selection: Binding(
                    get: { viewModel.appearance },
                    set: { viewModel.setAppearance($0) }
                )) {
                    ForEach(AppearanceSetting.allCases, id: \.self) { setting in
                        Text(setting.displayName).tag(setting)
                    }
                }
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

            // Conversations below Sounds (§4.5): the Text size popup sets
            // the Conversations window's body size 10-20pt (§9), the same
            // value cmd-plus / cmd-minus / cmd-0 adjust on the window itself.
            // A popup (same control family as the sound pickers above) lets
            // the owner jump straight to a size while watching the preview
            // (§8.44).
            Section("Conversations") {
                Picker("Text size", selection: Binding(
                    get: { conversationsTextSize.size },
                    set: { conversationsTextSize.set($0) }
                )) {
                    ForEach(textSizeOptions, id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
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
