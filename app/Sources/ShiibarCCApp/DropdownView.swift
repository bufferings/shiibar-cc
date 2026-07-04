// Dropdown custom view (the dropdown section of menubar-design.html,
// DESIGN.md §4.5): ⌄ menu (Back / Rescan / Mute Sound / Quit), warning rows
// (disconnected / notification permission denied / focus TCC error),
// grouped cards (Waiting / Working / Idle, empty groups hidden), two-line
// rows with unreviewed bolding + red dot, row click -> focus.

import ShiibarCCCore
import SwiftUI

struct DropdownView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TopBar(state: state)

            if !state.connected {
                WarningRow(text: "Disconnected from daemon — reconnecting…")
            }
            if state.notificationManager.permissionDenied {
                WarningRow(text: "Notifications permission denied")
            }
            if state.focusTCCWarning {
                WarningRow(text: "Focus failed: automation permission needed (run \"shiibar-cc doctor\")")
            }

            // The agent list renders inside a TimelineView so the "label ·
            // elapsed" second lines stay live: without it, this body is only
            // re-evaluated when AppState publishes a change, so the elapsed
            // strings froze at the last state mutation (seen on-device —
            // reopening the dropdown doesn't re-render either, since the
            // hosted view stays alive). Rows are recomputed from each
            // agent's `since` epoch against the timeline's date on every
            // tick. Cadence = 1s because the elapsed format has 1-second
            // granularity below one minute ("5s"), and the schedule only
            // ticks while the dropdown is actually visible.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let groups = state.groups(now: Int64(context.date.timeIntervalSince1970))
                if groups.isEmpty {
                    Text("No agents")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(groups) { group in
                                GroupSection(group: group, state: state)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 340)
    }
}

private struct TopBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack {
            Menu {
                Button("Back") { state.focusBack() }
                Button("Rescan") { state.runReconcile() }
                // A Toggle inside a Menu renders the native menu checkmark
                // while muted (the spec's "checkmark while muted").
                Toggle("Mute Sound", isOn: Binding(
                    get: { state.muted },
                    set: { _ in state.toggleMute() }
                ))
                Divider()
                Button("Quit") { state.quit() }
            } label: {
                Text("⌄").font(.system(size: 13, weight: .semibold))
            }
            // The macOS Menu draws its own pull-down disclosure indicator
            // next to the label, which stacked a second chevron under our ⌄
            // text (seen on-device). Hide it so exactly one ⌄ shows. If a
            // macOS version ignores `menuIndicator(.hidden)` for this style,
            // the fallback is the inverse: keep the system indicator and
            // make the label empty.
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }
}

private struct WarningRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text("⚠")
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

private struct GroupSection: View {
    let group: AgentGroup
    @ObservedObject var state: AppState

    private var heading: String {
        switch group.status {
        case .waiting: return "Waiting"
        case .working: return "Working"
        case .idle: return "Idle"
        case .unknown: return "Idle" // unreachable: Grouping.groupOrder never yields .unknown
        }
    }

    /// The header shows the tray-shaped window glyph carrying this group's
    /// own status character (menubar-design.html: group heading = window
    /// icon of the same shape as the tray, ~24px, + bold label).
    private var headerGlyph: TrayGlyph {
        switch group.status {
        case .waiting: return .waiting
        case .working: return .working
        case .idle: return .idle
        case .unknown: return .idle // unreachable, as above
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                WindowGlyphView(glyph: headerGlyph, size: 24)
                    // Optical adjustment from the mock: the label sits on the
                    // icon's vertical center, icon nudged up ~1.5pt.
                    .offset(y: -1.5)
                Text(heading)
                    .font(.system(size: 13, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            VStack(spacing: 1) {
                ForEach(group.rows) { row in
                    RowView(row: row, state: state)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.09)))
            .padding(.horizontal, 4)
        }
    }
}

private struct RowView: View {
    let row: AgentRow
    @ObservedObject var state: AppState

    var body: some View {
        Button {
            state.rowClicked(target: row.target)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.primaryLine)
                        .font(.system(size: 12, weight: row.unreviewed ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(row.label) · \(ElapsedTime.format(seconds: row.elapsedSeconds))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if row.unreviewed {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .padding(.top, 3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
