// Settings window (DESIGN.md §4.5 "Settings window" / §8.26/§8.27/§8.65):
// opened from the ⌄ menu's "Settings…" item, the app menu and ⌘,.
// Independent window, `NSApp.activate` on appear (an LSUIElement app's
// window otherwise opens behind other apps), no in-content close button —
// the title bar's red button / ⌘W is the only way to close, because every
// control here applies immediately (no "OK to confirm").
// Two tabs (`SettingsTab`): General — two headed boxes, General (Start at
// Login, Appearance, Text size, Global shortcut) and Sounds (Mute sound,
// Waiting sound, Done sound, Waiting above Done per the product's own
// waiting > working > idle priority) — and Setup Check (SetupCheckView.swift).
// Each row is a label with a one-line description on the left and one
// control in a fixed-width right column (§8.65: what a setting does is
// readable before it is touched; the controls line up). The window opens on
// General every time and its height follows the shown tab's content.
// Values are all UserDefaults-backed via `NotificationManager` (§4.5) or the
// text-size store — this file only wires them to SwiftUI and previews a
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

    /// Re-reads `SMAppService.mainApp.status` (never cached — DESIGN.md
    /// §4.5) so the window can't drift from System Settings' own Login
    /// Items UI.
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

/// The Settings window's dimensions (DESIGN.md §9 "Settings window
/// dimensions"; window-design.html "Settings window"). Fixed: the Settings
/// window does not follow the popover's text size (§4.5 "text size").
enum SettingsLayout {
    /// The window's width, the same on every tab.
    static let windowWidth: CGFloat = 600
    /// The content's padding below the tab row.
    static let contentTop: CGFloat = 16
    static let contentSide: CGFloat = 24
    static let contentBottom: CGFloat = 20
    /// Between one box and the next heading (and above `Re-run`).
    static let boxSpacing: CGFloat = 14
    /// Between a box's heading and the box; the heading's left indent.
    static let headingToBox: CGFloat = 6
    static let headingIndent: CGFloat = 4
    static let boxCornerRadius: CGFloat = 10
    static let boxBorder: CGFloat = 1
    /// A row's padding, its content's minimum height, the gap between the
    /// left and right columns, and the gap between label and description.
    static let rowVertical: CGFloat = 9
    static let rowHorizontal: CGFloat = 14
    static let rowMinContentHeight: CGFloat = 22
    static let columnSpacing: CGFloat = 12
    static let labelDescriptionSpacing: CGFloat = 2
    /// The right column: a fixed width, controls aligned to its right edge.
    static let controlColumnWidth: CGFloat = 240
    static let controlColumnSpacing: CGFloat = 8
    /// Type sizes (§4.5 "Settings window" look rules).
    static let labelFont: CGFloat = 13
    static let descriptionFont: CGFloat = 11
    static let headingFont: CGFloat = 12
    static let messageFont: CGFloat = 11
    /// Text size's number field (§4.5: 56pt, right-aligned; 4pt to the
    /// stepper).
    static let textSizeFieldWidth: CGFloat = 56
    static let textSizeStepperSpacing: CGFloat = 4
}

/// The tab row's dimensions (DESIGN.md §9 "Settings tab row dimensions").
enum SettingsTabBarLayout {
    static let rowVertical: CGFloat = 6
    static let rowHorizontal: CGFloat = 12
    static let buttonSpacing: CGFloat = 4
    static let buttonMinWidth: CGFloat = 72
    static let buttonVertical: CGFloat = 6
    static let buttonHorizontal: CGFloat = 8
    static let iconSize: CGFloat = 18
    static let iconNameSpacing: CGFloat = 3
    static let nameFont: CGFloat = 11
    static let selectedCornerRadius: CGFloat = 7
    /// The selected tab's ground: the accent color at this opacity.
    static let selectedTintOpacity: Double = 0.16
    /// The 1pt line under the tab row.
    static let bottomLine: CGFloat = 1
}

/// The color of an input error and a guidance line under a description
/// (DESIGN.md §9 "Settings error and guidance text color").
enum SettingsColors {
    static let messageNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xF0 / 255, green: 0x8A / 255, blue: 0x5D / 255, alpha: 1)
            : NSColor(srgbRed: 0xA0 / 255, green: 0x39 / 255, blue: 0x0A / 255, alpha: 1)
    }
}

/// The Settings window's tabs, left to right (DESIGN.md §4.5 "Settings
/// window").
enum SettingsTab: CaseIterable, Equatable {
    case general
    case setupCheck

    var title: String {
        switch self {
        case .general: return "General"
        case .setupCheck: return "Setup Check"
        }
    }

    /// SF Symbols: a gear for General, a checklist for Setup Check.
    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .setupCheck: return "checklist"
        }
    }
}

/// The kind of control in a row's right column (DESIGN.md §4.5 "Settings
/// window" look rules).
enum SettingsControlKind: Equatable {
    case toggleSwitch
    case segmented
    case numberFieldAndStepper
    case shortcutField
    case popup
}

/// One row of the General tab: its label, description and control (the
/// table in DESIGN.md §4.5 "Settings window").
enum SettingsRow: CaseIterable, Equatable {
    case startAtLogin
    case appearance
    case textSize
    case globalShortcut
    case muteSound
    case waitingSound
    case doneSound

    var label: String {
        switch self {
        case .startAtLogin: return "Start at Login"
        case .appearance: return "Appearance"
        case .textSize: return "Text size"
        case .globalShortcut: return "Global shortcut"
        case .muteSound: return "Mute sound"
        case .waitingSound: return "Waiting sound"
        case .doneSound: return "Done sound"
        }
    }

    var description: String {
        switch self {
        case .startAtLogin: return "Runs in the menu bar after you log in to your Mac"
        case .appearance: return "System follows the appearance setting of your Mac"
        case .textSize: return "Text in the popover and the window"
        case .globalShortcut: return "Shows the list from any app"
        case .muteSound: return "Notifications arrive silently"
        case .waitingSound: return "Plays when a session needs your input"
        case .doneSound: return "Plays when a session finishes responding"
        }
    }

    var control: SettingsControlKind {
        switch self {
        case .startAtLogin, .muteSound: return .toggleSwitch
        case .appearance: return .segmented
        case .textSize: return .numberFieldAndStepper
        case .globalShortcut: return .shortcutField
        case .waitingSound, .doneSound: return .popup
        }
    }
}

/// A headed box of rows.
struct SettingsBoxSpec: Equatable {
    let title: String
    let rows: [SettingsRow]
}

/// The General tab's boxes and rows, top to bottom (DESIGN.md §4.5
/// "Settings window").
enum SettingsGeneralLayout {
    static let boxes: [SettingsBoxSpec] = [
        SettingsBoxSpec(title: "General", rows: [.startAtLogin, .appearance, .textSize, .globalShortcut]),
        SettingsBoxSpec(title: "Sounds", rows: [.muteSound, .waitingSound, .doneSound]),
    ]
}

/// The Settings window's state across its tabs: the selected tab, which is
/// `General` every time the window opens (DESIGN.md §4.5 "tab on open"), and
/// what a tab switch does to the General tab's unfinished input. The window
/// is a SwiftUI `Window` scene whose content (and this model) outlives a
/// close, so the tab goes back to General when the window closes; choosing
/// Settings… while the window is open only brings it to the front and
/// leaves the tab as it is.
@MainActor
final class SettingsWindowModel: ObservableObject {
    @Published private(set) var selectedTab: SettingsTab = .general
    let general: SettingsViewModel
    let textSizeField: TextSizeFieldModel
    let hotKey: GlobalHotKeyModel
    let setupCheck: SetupCheckViewModel
    private let center: NotificationCenter
    private var closeObserver: NSObjectProtocol?

    init(
        general: SettingsViewModel,
        textSizeField: TextSizeFieldModel,
        hotKey: GlobalHotKeyModel,
        setupCheck: SetupCheckViewModel,
        center: NotificationCenter = .default
    ) {
        self.general = general
        self.textSizeField = textSizeField
        self.hotKey = hotKey
        self.setupCheck = setupCheck
        self.center = center
        // No queue: AppKit posts `willClose` on the main thread.
        closeObserver = center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: nil) { [weak self] notification in
            guard let window = notification.object as? NSWindow, window.title == SettingsWindow.title else { return }
            MainActor.assumeIsolated { self?.windowWillClose() }
        }
    }

    deinit {
        if let closeObserver { center.removeObserver(closeObserver) }
    }

    /// A click on a tab button (§4.5 "switching tabs"). Leaving General
    /// treats the Text size field's unfinished input as a focus loss (an
    /// edited value is applied, or its error shown) and abandons a Global
    /// shortcut recording; showing Setup Check runs the checks.
    func select(_ tab: SettingsTab) {
        guard tab != selectedTab else { return }
        if selectedTab == .general {
            textSizeField.commitIfEdited()
            hotKey.recordingAbandoned()
        }
        selectedTab = tab
        if tab == .setupCheck { setupCheck.tabShown() }
    }

    /// Settings… (⌄ menu, app menu, ⌘,): asks the scene to open or bring
    /// forward the window. The tab is left as it is — General after a
    /// close (`windowWillClose`), the shown tab while the window is open —
    /// and no check runs.
    func open(using openScene: (String) -> Void) {
        openScene(SettingsWindow.id)
    }

    /// The window is closing: the next open shows General, and a check run
    /// in flight is discarded when it lands (§4.5 "Setup Check tab").
    func windowWillClose() {
        selectedTab = .general
        setupCheck.windowClosed()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selected: model.selectedTab) { model.select($0) }
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: SettingsTabBarLayout.bottomLine)
            SettingsTabContent(model: model)
        }
        .frame(width: SettingsLayout.windowWidth)
        // The height follows the shown tab's content (§4.5 "window size":
        // no scrolling); `.windowResizability(.contentSize)` sizes the
        // window to it.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // `NSApp.activate` is required in an LSUIElement (accessory)
            // app: without it the window can open behind other apps (§4.5).
            NSApp.activate(ignoringOtherApps: true)
            model.general.refreshLoginItemStatus()
        }
    }
}

/// The shown tab's content inside the content padding.
struct SettingsTabContent: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        Group {
            switch model.selectedTab {
            case .general:
                SettingsGeneralTab(viewModel: model.general, textSizeField: model.textSizeField, hotKey: model.hotKey)
            case .setupCheck:
                SetupCheckTab(model: model.setupCheck)
            }
        }
        .padding(.top, SettingsLayout.contentTop)
        .padding(.horizontal, SettingsLayout.contentSide)
        .padding(.bottom, SettingsLayout.contentBottom)
    }
}

/// The tab row (DESIGN.md §4.5 "Settings window" > tab row; §9): the
/// buttons centered, an 18pt icon over an 11pt name, the selected one on a
/// rounded accent-tinted ground in the accent color. A click switches tabs;
/// the buttons never take the keyboard focus (no key operation switches
/// tabs).
struct SettingsTabBar: View {
    let selected: SettingsTab
    let onSelect: (SettingsTab) -> Void

    var body: some View {
        HStack(spacing: SettingsTabBarLayout.buttonSpacing) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SettingsTabBarLayout.rowVertical)
        .padding(.horizontal, SettingsTabBarLayout.rowHorizontal)
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = tab == selected
        let color = isSelected ? Color.accentColor : Color(nsColor: .labelColor)
        return VStack(spacing: SettingsTabBarLayout.iconNameSpacing) {
            Image(systemName: tab.symbolName)
                .resizable()
                .scaledToFit()
                .frame(width: SettingsTabBarLayout.iconSize, height: SettingsTabBarLayout.iconSize)
            Text(tab.title)
                .font(.system(size: SettingsTabBarLayout.nameFont))
        }
        .foregroundStyle(color)
        .padding(.vertical, SettingsTabBarLayout.buttonVertical)
        .padding(.horizontal, SettingsTabBarLayout.buttonHorizontal)
        .frame(minWidth: SettingsTabBarLayout.buttonMinWidth)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: SettingsTabBarLayout.selectedCornerRadius)
                    .fill(Color.accentColor.opacity(SettingsTabBarLayout.selectedTintOpacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(tab) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A headed box (window-design.html `.sh` + `.box`): the heading, then the
/// rows on the row frames' ground with a 1pt border, a 1pt line between
/// rows.
struct SettingsBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.headingToBox) {
            Text(title)
                .font(.system(size: SettingsLayout.headingFont, weight: .semibold))
                .padding(.leading, SettingsLayout.headingIndent)
            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.boxCornerRadius)
                    .fill(SurfaceColors.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.boxCornerRadius)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: SettingsLayout.boxBorder)
            )
        }
    }
}

/// The 1pt line between two rows of a box.
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
    }
}

/// One row (window-design.html `.it`): the label (13pt semibold) and its
/// description (11pt, secondary) on the left, an error or guidance line
/// under the description when there is one, and the control at the right
/// edge of the fixed-width right column.
struct SettingsRowView<Control: View>: View {
    let row: SettingsRow
    var message: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: SettingsLayout.columnSpacing) {
            VStack(alignment: .leading, spacing: SettingsLayout.labelDescriptionSpacing) {
                Text(row.label)
                    .font(.system(size: SettingsLayout.labelFont, weight: .semibold))
                Text(row.description)
                    .font(.system(size: SettingsLayout.descriptionFont))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                if let message {
                    Text(message)
                        .font(.system(size: SettingsLayout.messageFont))
                        .foregroundStyle(Color(nsColor: SettingsColors.messageNSColor))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: SettingsLayout.controlColumnSpacing) {
                Spacer(minLength: 0)
                control()
            }
            .frame(width: SettingsLayout.controlColumnWidth)
        }
        .frame(minHeight: SettingsLayout.rowMinContentHeight)
        .padding(.vertical, SettingsLayout.rowVertical)
        .padding(.horizontal, SettingsLayout.rowHorizontal)
    }
}

/// The General tab (§4.5 "Settings window"): the General and Sounds boxes.
struct SettingsGeneralTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var textSizeField: TextSizeFieldModel
    @ObservedObject var hotKey: GlobalHotKeyModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.boxSpacing) {
            ForEach(SettingsGeneralLayout.boxes, id: \.title) { box in
                SettingsBox(title: box.title) {
                    ForEach(Array(box.rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { SettingsRowDivider() }
                        rowView(row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: SettingsRow) -> some View {
        switch row {
        case .startAtLogin:
            SettingsRowView(row: row) {
                SettingsSwitch(isOn: Binding(
                    get: { viewModel.loginItemEnabled },
                    set: { _ in viewModel.toggleLoginItem() }
                ))
            }
        case .appearance:
            // Appearance (§4.5/§8.30): System / Light / Dark, default
            // System. Applies on pick, like every control here.
            SettingsRowView(row: row) {
                Picker(row.label, selection: Binding(
                    get: { viewModel.appearance },
                    set: { viewModel.setAppearance($0) }
                )) {
                    ForEach(AppearanceSetting.allCases, id: \.self) { setting in
                        Text(setting.displayName).tag(setting)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        case .textSize:
            TextSizeRow(field: textSizeField)
        case .globalShortcut:
            GlobalShortcutRow(hotKey: hotKey)
        case .muteSound:
            SettingsRowView(row: row) {
                SettingsSwitch(isOn: Binding(
                    get: { viewModel.muted },
                    set: { viewModel.setMuted($0) }
                ))
            }
        case .waitingSound:
            SettingsRowView(row: row) {
                soundPicker(row, selection: Binding(
                    get: { viewModel.waitingSoundName },
                    set: { viewModel.setWaitingSoundName($0) }
                ))
            }
        case .doneSound:
            SettingsRowView(row: row) {
                soundPicker(row, selection: Binding(
                    get: { viewModel.doneSoundName },
                    set: { viewModel.setDoneSoundName($0) }
                ))
            }
        }
    }

    /// A sound popup, disabled while Mute sound is ON (a setting with no
    /// effect is not offered — §4.5).
    private func soundPicker(_ row: SettingsRow, selection: Binding<String>) -> some View {
        Picker(row.label, selection: selection) {
            ForEach(viewModel.availableSoundNames, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .disabled(viewModel.muted)
    }
}

/// An ON / OFF switch at the small size (§4.5 "Settings window" look rules).
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}

/// Settings > General > Text size (§4.5 "Settings window"): a 56pt
/// right-aligned number field and the standard stepper, and the error line
/// under the description. The field applies on Enter and when it loses
/// focus, never per keystroke; closing the window while editing applies
/// nothing.
struct TextSizeRow: View {
    @ObservedObject var field: TextSizeFieldModel
    @FocusState private var isFocused: Bool
    /// False once the window is closing: the focus loss that follows must
    /// not apply the edit.
    @State private var isShown = false

    static let label = SettingsRow.textSize.label
    static let description = SettingsRow.textSize.description

    var body: some View {
        SettingsRowView(row: .textSize, message: field.error?.message) {
            HStack(spacing: SettingsLayout.textSizeStepperSpacing) {
                TextField(Self.label, text: $field.text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: SettingsLayout.textSizeFieldWidth)
                    .focused($isFocused)
                    .onSubmit { field.commit() }
                Stepper(Self.label, onIncrement: { field.stepUp() }, onDecrement: { field.stepDown() })
                    .labelsHidden()
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
