import XCTest

@testable import ShiibarCcCore

/// Settings > General > Terminal (DESIGN.md §4.5 "Settings window" >
/// Terminal, §4.6 "Resume and Branch", §9): the first value and the
/// migration of the old key, the stored value, whether the chosen terminal
/// can be used, and the messages. In-memory defaults; installed apps come
/// from an injected lookup (no real app is looked up).
final class ResumeTerminalTests: XCTestCase {
    private let iterm2ID = "com.googlecode.iterm2"
    private let terminalID = "com.apple.Terminal"
    private let ghosttyID = "com.mitchellh.ghostty"

    // MARK: - Constants (§9)

    func testValuesKeysAndBundleIdentifiers() {
        XCTAssertEqual(ResumeTerminal.allCases, [.iterm2, .appleTerminal, .ghostty])
        XCTAssertEqual(ResumeTerminal.allCases.map(\.displayName), ["iTerm2", "Terminal", "Ghostty"])
        XCTAssertEqual(ResumeTerminal.allCases.map(\.cliValue), ["iterm2", "apple-terminal", "ghostty"])
        XCTAssertEqual(ResumeTerminal.allCases.map(\.bundleIdentifier), [iterm2ID, terminalID, ghosttyID])
        XCTAssertEqual(ResumeTerminal.defaultsKey, "cc.shiibar.resumeTerminal")
        XCTAssertEqual(ResumeTerminal.legacyObservedTerminalKey, "cc.shiibar.lastObservedTerminal")
        XCTAssertEqual(ResumeTerminal.ghosttyMinimumVersion, TerminalVersion(major: 1, minor: 4, patch: 0))
    }

    // MARK: - First value at launch (§4.5)

    private func prepare(
        stored: Any? = nil, legacy: Any? = nil, installed: Set<ResumeTerminal>
    ) -> (ResumeTerminal, InMemoryDefaults) {
        let defaults = InMemoryDefaults()
        if let stored { defaults.set(stored, forKey: ResumeTerminal.defaultsKey) }
        if let legacy { defaults.set(legacy, forKey: ResumeTerminal.legacyObservedTerminalKey) }
        let value = ResumeTerminal.prepareAtLaunch(defaults: defaults) { installed.contains($0) }
        return (value, defaults)
    }

    /// The remembered kind (`iterm2` / `apple-terminal`) becomes the first
    /// value, whatever is installed, and the old key is removed.
    func testFirstValueTakesTheRememberedKind() {
        for (legacy, expected) in [("iterm2", ResumeTerminal.iterm2), ("apple-terminal", .appleTerminal)] {
            for installed in [Set<ResumeTerminal>(), [.iterm2], [.ghostty]] {
                let (value, defaults) = prepare(legacy: legacy, installed: installed)
                XCTAssertEqual(value, expected, "\(legacy) \(installed)")
                XCTAssertEqual(defaults.string(forKey: ResumeTerminal.defaultsKey), expected.rawValue)
                XCTAssertNil(defaults.object(forKey: ResumeTerminal.legacyObservedTerminalKey))
            }
        }
    }

    /// Nothing remembered: iTerm2 when installed, else Terminal; the value
    /// is stored.
    func testFirstValueWithoutARememberedKindFollowsWhetherITerm2IsInstalled() {
        XCTAssertEqual(prepare(installed: [.iterm2]).0, .iterm2)
        XCTAssertEqual(prepare(installed: [.iterm2, .ghostty]).0, .iterm2)
        let (value, defaults) = prepare(installed: [])
        XCTAssertEqual(value, .appleTerminal)
        XCTAssertEqual(defaults.string(forKey: ResumeTerminal.defaultsKey), "apple-terminal")
    }

    /// Ghostty is never the first value: with only Ghostty (and Terminal)
    /// installed the first value is Terminal; a remembered value that is not
    /// one of the two old kinds does not decide either.
    func testGhosttyIsNeverTheFirstValue() {
        XCTAssertEqual(prepare(installed: [.ghostty, .appleTerminal]).0, .appleTerminal)
        XCTAssertEqual(prepare(legacy: "ghostty", installed: [.ghostty]).0, .appleTerminal)
        XCTAssertEqual(prepare(legacy: "ghostty", installed: [.iterm2, .ghostty]).0, .iterm2)
        XCTAssertEqual(prepare(legacy: "tmux", installed: []).0, .appleTerminal)
        XCTAssertEqual(prepare(legacy: 3, installed: [.iterm2]).0, .iterm2)
    }

    /// A stored value that is none of the three choices counts as not
    /// stored: the first value is decided and stored over it.
    func testAStoredValueOutsideTheChoicesIsDecidedAgain() {
        for stored in ["tmux", "", "Ghostty", 7] as [Any] {
            let (value, defaults) = prepare(stored: stored, legacy: "apple-terminal", installed: [.iterm2])
            XCTAssertEqual(value, .appleTerminal, "\(stored)")
            XCTAssertEqual(defaults.string(forKey: ResumeTerminal.defaultsKey), "apple-terminal")
        }
    }

    /// A valid stored value stays as it is (decided once), and the old key
    /// is removed even then.
    func testAStoredValueIsKeptAndTheOldKeyIsRemovedAnyway() {
        for stored in ResumeTerminal.allCases {
            let (value, defaults) = prepare(stored: stored.rawValue, legacy: "iterm2", installed: [])
            XCTAssertEqual(value, stored)
            XCTAssertEqual(defaults.string(forKey: ResumeTerminal.defaultsKey), stored.rawValue)
            XCTAssertNil(defaults.object(forKey: ResumeTerminal.legacyObservedTerminalKey))
        }
    }

    /// Saved and loaded back through the defaults.
    func testSaveAndLoad() {
        let defaults = InMemoryDefaults()
        XCTAssertEqual(ResumeTerminal.load(from: defaults), .iterm2)
        for terminal in ResumeTerminal.allCases {
            ResumeTerminal.save(terminal, to: defaults)
            XCTAssertEqual(defaults.string(forKey: "cc.shiibar.resumeTerminal"), terminal.cliValue)
            XCTAssertEqual(ResumeTerminal.load(from: defaults), terminal)
        }
    }

    // MARK: - Version rule (§4.1, also for the installed Ghostty)

    func testVersionParsingUsesThePartBeforeTheFirstDashOrPlus() {
        XCTAssertEqual(TerminalVersion.parse("1.4.0"), TerminalVersion(major: 1, minor: 4, patch: 0))
        XCTAssertEqual(TerminalVersion.parse("1.4.0-main+abc1234"), TerminalVersion(major: 1, minor: 4, patch: 0))
        XCTAssertEqual(TerminalVersion.parse("1.4.0-dev+0000000"), TerminalVersion(major: 1, minor: 4, patch: 0))
        XCTAssertEqual(TerminalVersion.parse("1.4.0+abc"), TerminalVersion(major: 1, minor: 4, patch: 0))
        XCTAssertEqual(TerminalVersion.parse("1.3.1-main+abc1234"), TerminalVersion(major: 1, minor: 3, patch: 1))
        XCTAssertEqual(TerminalVersion.parse("1.10.2"), TerminalVersion(major: 1, minor: 10, patch: 2))
        for unreadable in ["", "1.4", "1.4.0.1", "v1.4.0", "1.4.x", "1..0", "-1.4.0", "1.4. 0"] {
            XCTAssertNil(TerminalVersion.parse(unreadable), unreadable)
        }
        XCTAssertLessThan(TerminalVersion(major: 1, minor: 3, patch: 9), ResumeTerminal.ghosttyMinimumVersion)
        XCTAssertLessThan(ResumeTerminal.ghosttyMinimumVersion, TerminalVersion(major: 1, minor: 10, patch: 0))
    }

    // MARK: - Availability (§4.5 "Settings window" > Terminal)

    private func availability(
        _ terminal: ResumeTerminal, _ apps: [String: InstalledTerminalApp]
    ) -> ResumeTerminalAvailability {
        ResumeTerminalAvailability.evaluate(terminal) { apps[$0] }
    }

    func testAvailabilityByBundleIdentifierAndGhosttyVersion() {
        XCTAssertEqual(availability(.iterm2, [iterm2ID: InstalledTerminalApp(shortVersion: "3.7.6")]), .available)
        XCTAssertEqual(availability(.iterm2, [iterm2ID: InstalledTerminalApp(shortVersion: nil)]), .available)
        XCTAssertEqual(availability(.iterm2, [ghosttyID: InstalledTerminalApp(shortVersion: "1.4.0")]),
                       .notInstalled(.iterm2))
        // Terminal is part of macOS: always usable, never looked up.
        var lookedUp: [String] = []
        XCTAssertEqual(ResumeTerminalAvailability.evaluate(.appleTerminal) { lookedUp.append($0); return nil },
                       .available)
        XCTAssertEqual(lookedUp, [])
        XCTAssertEqual(availability(.ghostty, [:]), .notInstalled(.ghostty))
        for version in ["1.4.0", "1.4.1", "1.10.0", "2.0.0", "1.4.0-main+abc1234"] {
            XCTAssertEqual(availability(.ghostty, [ghosttyID: InstalledTerminalApp(shortVersion: version)]),
                           .available, version)
        }
        for version in ["1.3.1", "1.3.0", "1.3.1-main+abc1234", "1.4", "garbage", nil] as [String?] {
            XCTAssertEqual(availability(.ghostty, [ghosttyID: InstalledTerminalApp(shortVersion: version)]),
                           .ghosttyTooOld, version ?? "nil")
        }
    }

    /// The Settings line and the Resume / Branch tooltip (§4.5, §4.6).
    func testMessages() {
        XCTAssertNil(ResumeTerminalAvailability.available.settingsMessage)
        XCTAssertNil(ResumeTerminalAvailability.available.buttonTooltip)
        XCTAssertEqual(ResumeTerminalAvailability.notInstalled(.iterm2).settingsMessage, "iTerm2 is not installed")
        XCTAssertEqual(ResumeTerminalAvailability.notInstalled(.ghostty).settingsMessage, "Ghostty is not installed")
        XCTAssertEqual(ResumeTerminalAvailability.ghosttyTooOld.settingsMessage, "Ghostty 1.4.0 or later is required")
        XCTAssertEqual(ResumeTerminalAvailability.notInstalled(.iterm2).buttonTooltip,
                       "iTerm2 is not installed \u{2014} choose a terminal in Settings")
        XCTAssertEqual(ResumeTerminalAvailability.notInstalled(.ghostty).buttonTooltip,
                       "Ghostty is not installed \u{2014} choose a terminal in Settings")
        XCTAssertEqual(ResumeTerminalAvailability.ghosttyTooOld.buttonTooltip,
                       "Ghostty 1.4.0 or later is required \u{2014} choose a terminal in Settings")
    }

    // MARK: - Resume and Branch while the terminal cannot be used (§4.6)

    private func agent(target: String, sessionID: String) -> Agent {
        Agent(target: target, status: .idle, unreviewed: false, sessionId: sessionID,
              cwd: "/Users/example/demo", task: nil, message: nil, since: 0, lastSeen: 0)
    }

    private func summary(_ sessionID: String, cwd: String?) -> ConversationSummary {
        ConversationSummary(sessionID: sessionID, cwd: cwd, title: "t", updatedAt: 0, live: false)
    }

    /// Resume and Branch are disabled with the terminal's reason; Jump
    /// (enabled, or the disabled Jump of an undrivable session) is not
    /// touched.
    func testUnusableTerminalDisablesResumeAndBranchButNotJump() {
        let reason = ResumeTerminalAvailability.notInstalled(.ghostty)
        let tooltip = "Ghostty is not installed \u{2014} choose a terminal in Settings"
        let resume = ConversationAction.resume.button(sessionID: "h1", cwd: "/Users/example/demo")
        XCTAssertEqual(resume.applying(reason), RowButton(kind: .resume, invocation: nil, tooltip: tooltip))
        let branch = ConversationAction.branchButton(sessionID: "h1", cwd: "/Users/example/demo")
        XCTAssertEqual(branch.applying(reason), RowButton(kind: .branch, invocation: nil, tooltip: tooltip))
        let jump = ConversationAction.jump(target: "iterm2:w0t0p0:U").button(sessionID: "s1", cwd: "/c")
        XCTAssertEqual(jump.applying(reason), jump)
        XCTAssertEqual(RowButton.undrivableJump.applying(reason), RowButton.undrivableJump)
        XCTAssertEqual(resume.applying(.available), resume)
        XCTAssertEqual(branch.applying(.available), branch)
    }

    /// Already disabled for a missing cwd (or session_id): the terminal's
    /// reason replaces the `Resume` / `Branch` tooltip (§4.6: when both
    /// apply, the terminal's reason shows). Usable: the tooltip stays.
    func testTerminalReasonWinsOverAMissingCwd() {
        let reason = ResumeTerminalAvailability.ghosttyTooOld
        let tooltip = "Ghostty 1.4.0 or later is required \u{2014} choose a terminal in Settings"
        let noCwdResume = ConversationAction.resumeDisabled.button(sessionID: "h1", cwd: nil)
        XCTAssertEqual(noCwdResume.tooltip, "Resume")
        XCTAssertEqual(noCwdResume.applying(reason), RowButton(kind: .resume, invocation: nil, tooltip: tooltip))
        XCTAssertEqual(noCwdResume.applying(.available), noCwdResume)
        let noCwdBranch = ConversationAction.branchButton(sessionID: "h1", cwd: nil)
        XCTAssertEqual(noCwdBranch.applying(reason).tooltip, tooltip)
        let noSessionBranch = ConversationAction.branchButton(sessionID: "", cwd: "/c")
        XCTAssertEqual(noSessionBranch.applying(reason).tooltip, tooltip)
        XCTAssertEqual(noSessionBranch.applying(.available).tooltip, "Branch")
    }

    /// The list applies the availability to every section's rows, and puts
    /// the buttons back when the terminal can be used again.
    func testListStateAppliesAvailabilityToEveryRow() {
        var state = UnifiedListState(home: "/Users/example", now: 100)
        _ = state.handle(.agentsUpdated([
            agent(target: "iterm2:w0t0p0:U", sessionID: "s1"),
            agent(target: "process:4242", sessionID: "s2"),
        ]))
        _ = state.handle(.historyDelivered(
            [summary("h1", cwd: "/Users/example/demo"), summary("h2", cwd: nil)], isFiltered: false))
        let reason = ResumeTerminalAvailability.notInstalled(.iterm2)
        _ = state.handle(.resumeTerminalAvailabilityChanged(reason))
        XCTAssertEqual(state.resumeTerminalAvailability, reason)
        XCTAssertEqual(state.runningRows.count, 2)
        XCTAssertEqual(state.recentRows.count, 2)
        for row in state.runningRows + state.recentRows {
            XCTAssertEqual(row.branchButton, RowButton(kind: .branch, invocation: nil, tooltip: reason.buttonTooltip!))
        }
        for row in state.recentRows {
            XCTAssertEqual(row.primaryButton, RowButton(kind: .resume, invocation: nil, tooltip: reason.buttonTooltip!))
        }
        let jumps = Dictionary(uniqueKeysWithValues: state.runningRows.map { ($0.sessionID, $0.primaryButton) })
        XCTAssertEqual(jumps["s1"]?.invocation, .jump(target: "iterm2:w0t0p0:U"))
        XCTAssertEqual(jumps["s2"], .undrivableJump)

        _ = state.handle(.resumeTerminalAvailabilityChanged(.available))
        XCTAssertTrue(state.runningRows.allSatisfy { $0.branchButton.isEnabled })
        XCTAssertEqual(state.recentRows.first { $0.sessionID == "h1" }?.primaryButton.invocation,
                       .resume(sessionID: "h1", cwd: "/Users/example/demo"))
        XCTAssertEqual(state.recentRows.first { $0.sessionID == "h2" }?.primaryButton.tooltip, "Resume")
    }
}
