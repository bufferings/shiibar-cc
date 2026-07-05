// Setup Check window (DESIGN.md §4.5, M5 T5): parses `shiibar-cc doctor
// --json` (§4.4) into rows, and builds the two rows the CLI can't produce
// itself (notification permission / Login Item status — both only readable
// from inside the running app). Judgement logic for the CLI-derived checks
// stays entirely in the CLI ("doctor is the source of truth", §4.5) — this
// file only reshapes already-decided ok/warn/fail records into the row model
// the window displays, plus decides the row for the two app-only checks.
// UNUserNotificationCenter / SMAppService I/O stays in the app layer
// (SetupCheckView); this is pure logic so it's independently testable
// against fixture JSON strings.

import Foundation

/// ok / warn / fail (DESIGN.md §4.4's JSON schema). An unrecognized status
/// string (e.g. a newer CLI version's future value) decodes to `.warn`
/// rather than failing to parse the whole row — a forward-compat default
/// that surfaces the anomaly without either hiding it (`.ok`) or overstating
/// it as a hard failure (`.fail`) sight unseen.
public enum SetupCheckStatus: String, Equatable, Sendable {
    case ok
    case warn
    case fail

    /// Maps a wire status string to a case, defaulting unrecognized values
    /// to `.warn` (see the type's doc comment). Not `init?(rawValue:)`
    /// (RawRepresentable's own failable initializer, still synthesized
    /// as-is) precisely because this one never fails.
    public static func from(wireValue: String) -> SetupCheckStatus {
        switch wireValue {
        case "ok": return .ok
        case "fail": return .fail
        default: return .warn
        }
    }

    /// The ✓/⚠/✗ glyph the window shows at the start of each row (§4.5).
    public var symbol: String {
        switch self {
        case .ok: return "✓"
        case .warn: return "⚠"
        case .fail: return "✗"
        }
    }
}

/// One row of the Setup Check window: a CLI check (from `doctor --json`) or
/// one of the two app-only checks (notification permission / Login Item).
public struct SetupCheckRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let status: SetupCheckStatus
    public let summary: String
    /// Secondary-text pointer to how to fix the problem, if there's
    /// something actionable to say (§4.5: "各行に対処のヒントを一言").
    public let hint: String?

    public init(id: String, status: SetupCheckStatus, summary: String, hint: String?) {
        self.id = id
        self.status = status
        self.summary = summary
        self.hint = hint
    }
}

/// `shiibar-cc doctor --json`'s wire shape (§4.4): `{"checks":[{"id",
/// "status","summary","hint"}]}`. Field names already match Rust's
/// `CheckRecord` verbatim (no snake_case translation needed).
private struct DoctorCheckWire: Decodable {
    let id: String
    let status: String
    let summary: String
    let hint: String?
}

private struct DoctorChecksWire: Decodable {
    let checks: [DoctorCheckWire]
}

public enum SetupCheckParsing {
    /// Parses `shiibar-cc doctor --json` stdout into rows. Malformed input
    /// (empty stdout, a CLI that predates `--json`, truncated output) yields
    /// a single fail row describing the parse failure rather than throwing
    /// or returning nothing — the window's job is exactly to surface "is the
    /// setup broken", and an unparseable doctor result is itself such a
    /// finding.
    public static func parseDoctorJSON(_ json: String) -> [SetupCheckRow] {
        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(DoctorChecksWire.self, from: data)
        else {
            return [
                SetupCheckRow(
                    id: "doctor",
                    status: .fail,
                    summary: "Could not parse `shiibar-cc doctor --json` output",
                    hint: "run `shiibar-cc doctor` in a terminal to see the raw error"
                ),
            ]
        }
        return wire.checks.map { check in
            SetupCheckRow(
                id: check.id,
                status: SetupCheckStatus.from(wireValue: check.status),
                summary: check.summary,
                hint: check.hint
            )
        }
    }
}

/// Notification authorization, reduced to the three states the row builder
/// cares about (mirrors `UNAuthorizationStatus`, without importing
/// UserNotifications into this Foundation-only module — the app layer maps
/// the real enum onto this one).
public enum NotificationPermissionState: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
}

/// Row builders for the two checks only the running app can answer (§4.5).
/// Judgement here is intentionally the mirror image of doctor's: these
/// aren't the CLI's business (a headless CLI process has no notification
/// authorization or Login Item registration of its own to report on).
public enum SetupCheckAppSideRows {
    public static func notificationPermissionRow(state: NotificationPermissionState) -> SetupCheckRow {
        switch state {
        case .authorized:
            return SetupCheckRow(
                id: "notification_permission",
                status: .ok,
                summary: "Notification permission granted",
                hint: nil
            )
        case .denied:
            return SetupCheckRow(
                id: "notification_permission",
                status: .fail,
                summary: "Notification permission denied",
                hint: "System Settings > Notifications > Shiibar CC"
            )
        case .notDetermined:
            return SetupCheckRow(
                id: "notification_permission",
                status: .warn,
                summary: "Notification permission not yet requested",
                hint: "relaunch the app, or open System Settings > Notifications > Shiibar CC"
            )
        }
    }

    public static func loginItemRow(enabled: Bool) -> SetupCheckRow {
        if enabled {
            return SetupCheckRow(
                id: "login_item",
                status: .ok,
                summary: "Start at Login is enabled",
                hint: nil
            )
        }
        return SetupCheckRow(
            id: "login_item",
            status: .warn,
            summary: "Start at Login is disabled",
            hint: "enable it from the ⌄ menu > Settings > Start at Login"
        )
    }
}
