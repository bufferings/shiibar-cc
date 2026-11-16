// Settings window (DESIGN.md §4.5 "Settings window" / §8.26/§8.27):
// opened from the ⌄ menu's "Settings…" item (replacing the old Settings
// submenu, M14 T1). Independent window, `NSApp.activate` on appear (same
// LSUIElement requirement as Setup Check), no in-content close button — the
// title bar's red button / ⌘W is the only way to close, because every
// control here applies immediately (no "OK to confirm"). Two groups:
// General (Start at Login, reusing AppState's existing SMAppService
// read/write; Appearance = System / Light / Dark, §8.30/M27 T5; Text size,
// the number field and stepper for the popover's and the window's text
// size — §4.5 "text size", the same live value their ⌘= / ⌘− / ⌘0 keys
// read and write via the shared `TextSizeStore`; Global shortcut, the
// global hotkey's combination — §4.5/§8.50) and Sounds (Mute sound /
// Waiting sound / Done sound, Waiting above Done per the product's own
// waiting > working > idle priority).
// Values are all UserDefaults-backed via `NotificationManager` (§4.5) or the
// text-size store — this view only wires them to SwiftUI and previews a
// sound pick via `NSSound(named:)` (direct playback, not through a
// notification — the pick is a user-initiated action, not an event, §4.5).

import AppKit
import Combine
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

/// The Settings window's Text size field and stepper (§4.5 "Settings
/// window"): the field's text, its error line, and the applying rules. The
/// parsing and the messages come from `TextSize`.
@MainActor
final class TextSizeFieldModel: ObservableObject {
    /// What the field shows; edited freely, applied only by `commit()`.
    @Published var text: String
    /// The error under the description, until the next applied value.
    @Published private(set) var error: TextSize.InputError?

    private let store: TextSizeStore
    private var subscription: AnyCancellable?
    /// The text this model last put in the field: the field is edited when
    /// its text differs.
    private var shownText: String

    init(store: TextSizeStore) {
        self.store = store
        let initial = Self.text(for: store.size)
        self.text = initial
        self.shownText = initial
        // A value applied from anywhere (this field, the stepper, the keys
        // in the popover and the window) shows in the field and clears the
        // error.
        subscription = store.$size
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] size in
                MainActor.assumeIsolated { self?.valueApplied(size) }
            }
    }

    var size: TextSize { store.size }

    /// Enter or focus loss: apply a valid value (the same value included,
    /// which also clears the error); otherwise show the error and put the
    /// current value back in the field.
    func commit() {
        switch TextSize.parse(text) {
        case .success(let value):
            if !store.apply(value) { valueApplied(value) }
        case .failure(let failure):
            error = failure
            show(store.size)
        }
    }

    /// Focus loss: applies like Enter, but only an edited field (leaving a
    /// field that shows the current value applies nothing).
    func commitIfEdited() {
        guard text != shownText else { return }
        commit()
    }

    /// Put the current value back without applying (the Settings window
    /// closed while the field was being edited, or it is shown again).
    func discardEdit() {
        show(store.size)
    }

    /// The stepper's up arrow: one larger; nothing at the maximum.
    func stepUp() {
        if let next = store.size.larger { store.apply(next) }
    }

    /// The stepper's down arrow: one smaller; nothing at the minimum.
    func stepDown() {
        if let next = store.size.smaller { store.apply(next) }
    }

    private func valueApplied(_ size: TextSize) {
        show(size)
        error = nil
    }

    private func show(_ size: TextSize) {
        shownText = Self.text(for: size)
        text = shownText
    }

    private static func text(for size: TextSize) -> String { String(size.points) }
}

struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    /// The Text size field over the shared store (§4.5): a key change from
    /// the popover or the window moves the field live.
    @StateObject private var textSizeField: TextSizeFieldModel
    /// The global hotkey's registration (§4.5 "global hotkey"), shared with
    /// the surface controller that receives the presses.
    @ObservedObject private var hotKey: GlobalHotKeyModel

    init(
        notificationManager: NotificationManager,
        loginItemEnabledProvider: @escaping () -> Bool,
        toggleLoginItem: @escaping () -> Void,
        appearanceSetting: AppearanceSetting,
        setAppearance: @escaping (AppearanceSetting) -> Void,
        textSize: TextSizeStore,
        hotKey: GlobalHotKeyModel
    ) {
        self.hotKey = hotKey
        _viewModel = StateObject(wrappedValue: SettingsViewModel(
            notificationManager: notificationManager,
            loginItemEnabledProvider: loginItemEnabledProvider,
            toggleLoginItem: toggleLoginItem,
            appearanceSetting: appearanceSetting,
            setAppearance: setAppearance
        ))
        _textSizeField = StateObject(wrappedValue: TextSizeFieldModel(store: textSize))
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
            SettingsGeneralSection(viewModel: viewModel, textSizeField: textSizeField, hotKey: hotKey)

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
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // `NSApp.activate` is required in an LSUIElement (accessory)
            // app, same as Setup Check (§4.5).
            NSApp.activate(ignoringOtherApps: true)
            viewModel.refreshLoginItemStatus()
        }
    }

    static let width: CGFloat = 380
}

/// Settings > General (§4.5): Start at Login, Appearance, Text size, Global
/// shortcut.
struct SettingsGeneralSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var textSizeField: TextSizeFieldModel
    @ObservedObject var hotKey: GlobalHotKeyModel

    var body: some View {
        Section("General") {
            Toggle("Start at Login", isOn: Binding(
                get: { viewModel.loginItemEnabled },
                set: { _ in viewModel.toggleLoginItem() }
            ))

            // Appearance (§4.5/§8.30, M27 T5): System / Light / Dark,
            // default System — the OS can stay light while this app
            // (the popover and the window in particular) goes dark. Applies on pick, like every control here.
            Picker("Appearance", selection: Binding(
                get: { viewModel.appearance },
                set: { viewModel.setAppearance($0) }
            )) {
                ForEach(AppearanceSetting.allCases, id: \.self) { setting in
                    Text(setting.displayName).tag(setting)
                }
            }

            // Text size (§4.5 "text size"): right after Appearance.
            TextSizeRow(field: textSizeField)

            // Global shortcut (§4.5 / §8.50): records the global hotkey's
            // combination; registers it the moment it is recorded.
            GlobalShortcutRow(hotKey: hotKey)
        }
    }
}

/// Settings > General > Text size (§4.5 "Settings window"): a 56pt
/// right-aligned number field and the standard stepper, the description,
/// and the error line under it. The field applies on Enter and when it loses
/// focus, never per keystroke; closing the window while editing applies
/// nothing.
struct TextSizeRow: View {
    @ObservedObject var field: TextSizeFieldModel
    @FocusState private var isFocused: Bool
    /// False once the window is closing: the focus loss that follows must
    /// not apply the edit.
    @State private var isShown = false

    static let label = "Text size"
    static let description = "Text in the popover and the window"
    private static let fieldWidth: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(Self.label) {
                HStack(spacing: 4) {
                    TextField(Self.label, text: $field.text)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: Self.fieldWidth)
                        .focused($isFocused)
                        .onSubmit { field.commit() }
                    Stepper(Self.label, onIncrement: { field.stepUp() }, onDecrement: { field.stepDown() })
                        .labelsHidden()
                }
            }
            Text(Self.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let error = field.error {
                Text(error.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            isShown = true
            field.discardEdit()
        }
        .onDisappear {
            isShown = false
            field.discardEdit()
        }
        .onChange(of: isFocused) { _, focused in
            guard !focused else { return }
            // Deferred a turn: a window close reports the disappearance
            // after the focus loss.
            DispatchQueue.main.async {
                guard isShown else { return }
                field.commitIfEdited()
            }
        }
    }
}
