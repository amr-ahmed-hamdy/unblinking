import XCTest
@testable import Unblinking

final class CaffeineArgumentTests: XCTestCase {
    private func arguments(
        display: Bool = false,
        idle: Bool = false,
        disk: Bool = false,
        systemOnAC: Bool = false,
        duration: SessionDuration = .indefinite,
        watchPID: pid_t = 4242
    ) -> [String] {
        CaffeineProcess.arguments(
            options: .init(display: display, idle: idle, disk: disk, systemOnAC: systemOnAC),
            duration: duration,
            watchPID: watchPID
        )
    }

    func testWatchdogIsAlwaysPresent() {
        // -w is what stops a crashed app leaving an orphaned caffeinate behind, so it
        // must survive every combination of options.
        for display in [true, false] {
            for idle in [true, false] {
                let args = arguments(display: display, idle: idle, watchPID: 99)
                XCTAssertEqual(args.suffix(2), ["-w", "99"])
            }
        }
    }

    func testEachAssertionFlagIsEmitted() {
        let args = arguments(display: true, idle: true, disk: true, systemOnAC: true)
        XCTAssertEqual(args, ["-d", "-i", "-m", "-s", "-w", "4242"])
    }

    func testFallsBackToIdleWhenNothingSelected() {
        // Holding zero assertions would make the app look active while doing nothing.
        XCTAssertEqual(arguments(), ["-i", "-w", "4242"])
    }

    func testTimedSessionAddsTimeout() {
        let args = arguments(idle: true, duration: .seconds(900))
        XCTAssertEqual(args, ["-i", "-t", "900", "-w", "4242"])
    }

    func testIndefiniteSessionOmitsTimeout() {
        XCTAssertFalse(arguments(idle: true, duration: .indefinite).contains("-t"))
    }
}

final class SleepDisabledParsingTests: XCTestCase {
    /// Trimmed from real `pmset -g live` output on macOS 26.
    private let sample = """
        System-wide power settings:
         SleepDisabled\t\t0
        Currently in use:
         standby              1
         sleep                0 (sleep prevented by caffeinate, Arc, powerd)
         displaysleep         10 (display sleep prevented by Arc)
        """

    func testParsesDisabledZero() {
        XCTAssertEqual(SleepDisabledFlag.parse(from: sample), false)
    }

    func testParsesDisabledOne() {
        let enabled = sample.replacingOccurrences(
            of: "SleepDisabled\t\t0",
            with: "SleepDisabled\t\t1"
        )
        XCTAssertEqual(SleepDisabledFlag.parse(from: enabled), true)
    }

    func testReturnsNilWhenAbsent() {
        XCTAssertNil(SleepDisabledFlag.parse(from: "Currently in use:\n sleep 0"))
    }

    func testIgnoresSimilarlyNamedKeys() {
        XCTAssertNil(SleepDisabledFlag.parse(from: " NotSleepDisabled 1"))
    }
}

final class StrayProcessParsingTests: XCTestCase {
    func testParsesPidAndFullCommand() {
        let output = """
          48568 caffeinate -i -t 300
          49001 /usr/bin/caffeinate -dimsu
        """
        let parsed = StrayProcessWatcher.parse(psOutput: output)

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].pid, 48568)
        XCTAssertEqual(parsed[0].command, "caffeinate -i -t 300")
        XCTAssertEqual(parsed[1].pid, 49001)
        XCTAssertEqual(parsed[1].command, "/usr/bin/caffeinate -dimsu")
    }

    func testSkipsMalformedLines() {
        XCTAssertTrue(StrayProcessWatcher.parse(psOutput: "\n  \nnotanumber foo\n").isEmpty)
    }
}

final class SudoersRuleTests: XCTestCase {
    /// sudo skips files in an @includedir whose names contain "." or end in "~". A rule
    /// under such a name installs cleanly, looks correct in `ls -l`, and is never read —
    /// which is exactly the failure this app shipped with first time around.
    func testRuleFileNameIsOneSudoWillActuallyRead() {
        XCTAssertTrue(
            SudoersRunner.ruleFileNameIsLoadable(SudoersRunner.ruleFileName),
            "\(SudoersRunner.ruleFileName) would be silently ignored by sudo"
        )
        XCTAssertFalse(SudoersRunner.ruleFilePath.hasSuffix("~"))
    }

    func testLoadableNameRules() {
        XCTAssertTrue(SudoersRunner.ruleFileNameIsLoadable("caffeinate-app"))
        XCTAssertTrue(SudoersRunner.ruleFileNameIsLoadable("10_caffeinate"))
        XCTAssertFalse(SudoersRunner.ruleFileNameIsLoadable("com.amrhamdy.unblinking"))
        XCTAssertFalse(SudoersRunner.ruleFileNameIsLoadable("caffeinate.conf"))
        XCTAssertFalse(SudoersRunner.ruleFileNameIsLoadable("caffeinate~"))
        XCTAssertFalse(SudoersRunner.ruleFileNameIsLoadable(""))
    }

    /// Every legacy path must stay distinct from the current one, or install-time cleanup
    /// would delete the rule it had just written.
    func testLegacyPathsAreCleanedUpAndAreNotTheCurrentPath() {
        XCTAssertFalse(
            SudoersRunner.legacyRuleFilePaths.contains(SudoersRunner.ruleFilePath),
            "install removes every legacy path, so the live path must not be among them"
        )
        XCTAssertFalse(SudoersRunner.legacyRuleFilePaths.isEmpty)
        XCTAssertFalse(SudoersRunner.ruleFileNameIsLoadable("com.amrhamdy.unblinking"))
    }

    /// A grant that only exists under an old file name must not count as installed, or the
    /// app would never migrate and would leave a stale rule in /etc forever.
    func testAuthorizationRequiresTheCurrentFileName() {
        let runner = SudoersRunner()
        let currentExists = FileManager.default.fileExists(atPath: SudoersRunner.ruleFilePath)
        if !currentExists {
            XCTAssertFalse(
                runner.isAuthorizationInstalled,
                "with no rule at \(SudoersRunner.ruleFilePath), authorization must read as "
                    + "missing even if a legacy rule still grants the commands"
            )
        }
    }

    /// Renaming the app must not strand a working grant under the old name.
    func testEveryPreviousRuleNameIsListedForCleanup() {
        for previous in ["com.amrhamdy.caffeinate", "caffeinate-app"] {
            XCTAssertTrue(
                SudoersRunner.legacyRuleFilePaths.contains("/etc/sudoers.d/\(previous)"),
                "\(previous) shipped at some point and must still be cleaned up"
            )
        }
    }

    func testRuleGrantsOnlyTheTwoExpectedCommands() {
        let rule = SudoersRunner.ruleText(user: "testuser")
        let directive = rule
            .split(separator: "\n")
            .first { !$0.hasPrefix("#") && !$0.isEmpty }

        XCTAssertEqual(
            directive.map(String.init),
            "testuser ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, "
                + "/usr/bin/pmset -a disablesleep 1"
        )
        XCTAssertFalse(rule.contains("*"), "A wildcard would widen this well past pmset")
        XCTAssertFalse(rule.contains("ALL=(ALL)"))
    }

    /// The real safety net: a malformed sudoers file can lock the user out of sudo, so
    /// the generated text must satisfy visudo before it is ever installed.
    func testGeneratedRulePassesVisudo() throws {
        let rule = SudoersRunner.ruleText(user: NSUserName())
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("caffeinate-rule-test-\(UUID().uuidString)")
        try rule.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let result = Shell.run("/usr/sbin/visudo", ["-c", "-f", path.path])
        XCTAssertTrue(result.succeeded, "visudo rejected the rule: \(result.combinedOutput)")
    }

    func testRejectsUserNamesThatCouldBreakTheRule() {
        XCTAssertTrue(SudoersRunner.isValidUserName("amrhamdy"))
        XCTAssertTrue(SudoersRunner.isValidUserName("first.last_2"))
        XCTAssertFalse(SudoersRunner.isValidUserName(""))
        XCTAssertFalse(SudoersRunner.isValidUserName("bad name"))
        XCTAssertFalse(SudoersRunner.isValidUserName("evil\nALL=(ALL) NOPASSWD: ALL"))
        XCTAssertFalse(SudoersRunner.isValidUserName("quote\"user"))
    }

    /// The rule must never pass through a file an unprivileged process can write.
    ///
    /// Regression guard for a root escalation: the rule used to be staged in the user's
    /// temp directory and validated there, leaving the whole duration of the password
    /// dialog for same-uid malware to swap the contents before root read them.
    func testInstallNeverStagesTheRuleOutsideRoot() {
        let script = SudoersRunner.installScript(user: "testuser")

        XCTAssertTrue(
            script.contains("/private/var/root/"),
            "the rule must be staged somewhere only root can write"
        )
        for userWritable in ["/tmp/", "/var/folders/", "$TMPDIR", "unblinking-sudoers-"] {
            XCTAssertFalse(
                script.contains(userWritable),
                "\(userWritable) is reachable by an unprivileged process"
            )
        }
    }

    /// visudo must check the same bytes install copies. Validating one file and installing
    /// another is the whole bug.
    func testValidationAndInstallTargetTheSameFile() {
        let script = SudoersRunner.installScript(user: "testuser")
        XCTAssertTrue(script.contains("/usr/sbin/visudo -cf \"$d/rule\""))
        XCTAssertTrue(script.contains("install -m 0440 -o root -g wheel \"$d/rule\""))
        XCTAssertTrue(
            script.range(of: "visudo")!.lowerBound < script.range(of: "install -m")!.lowerBound,
            "validation must precede installation"
        )
    }

    /// An unquoted heredoc delimiter would let the shell expand the rule text.
    func testHeredocIsQuotedAndUnguessable() {
        let script = SudoersRunner.installScript(user: "testuser")
        XCTAssertTrue(script.contains("<<'UNBLINKING_RULE_"), "delimiter must be quoted")
        XCTAssertNotEqual(
            SudoersRunner.installScript(user: "testuser"),
            SudoersRunner.installScript(user: "testuser"),
            "the delimiter should be random per invocation"
        )
    }

    /// The script is multi-line, and AppleScript string literals cannot span lines — so
    /// the escaping has to survive a round trip or the install silently breaks.
    func testMultiLineScriptSurvivesAppleScriptEscaping() {
        let escaped = SudoersRunner.escapeForAppleScript(
            SudoersRunner.installScript(user: "testuser")
        )
        XCTAssertFalse(escaped.contains("\n"), "a raw newline is a syntax error in AppleScript")
        XCTAssertTrue(escaped.contains("\\n"), "newlines must travel as escapes")
        XCTAssertFalse(escaped.contains("\"$d/rule\""), "unescaped quotes would end the literal")
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual(
            SudoersRunner.escapeForAppleScript(#"/bin/rm -f "/tmp/a b""#),
            #"/bin/rm -f \"/tmp/a b\""#
        )
        XCTAssertEqual(
            SudoersRunner.escapeForAppleScript(#"back\slash"#),
            #"back\\slash"#
        )
    }
}

final class ClickRoutingTests: XCTestCase {
    private func action(
        _ type: NSEvent.EventType?,
        _ modifiers: NSEvent.ModifierFlags = []
    ) -> StatusItemController.ClickAction {
        StatusItemController.action(eventType: type, modifiers: modifiers)
    }

    func testLeftClickToggles() {
        XCTAssertEqual(action(.leftMouseUp), .toggle)
    }

    func testRightClickOpensTheMenu() {
        XCTAssertEqual(action(.rightMouseUp), .showMenu)
    }

    func testControlClickOpensTheMenu() {
        XCTAssertEqual(action(.leftMouseUp, .control), .showMenu)
    }

    /// VoiceOver and other assistive presses arrive with no mouse event at all. Dropping
    /// those made the status item completely unusable without a mouse.
    func testPressWithNoMouseEventStillToggles() {
        XCTAssertEqual(action(nil), .toggle)
        XCTAssertEqual(action(nil, []), .toggle)
    }

    func testOtherModifiersDoNotOpenTheMenu() {
        XCTAssertEqual(action(.leftMouseUp, .shift), .toggle)
        XCTAssertEqual(action(.leftMouseUp, .option), .toggle)
        XCTAssertEqual(action(.leftMouseUp, .command), .toggle)
    }
}

extension StatusItemController.ClickAction: Equatable {}

final class IconStyleTests: XCTestCase {
    func testOnlyVividAnimates() {
        XCTAssertTrue(IconStyle.vivid.isAnimated)
        XCTAssertFalse(IconStyle.colour.isAnimated)
        XCTAssertFalse(IconStyle.subtle.isAnimated)
    }

    /// Reduce Motion is an accessibility setting, so it overrides the chosen style rather
    /// than being merged with it — but only by removing motion, never colour.
    func testReduceMotionDemotesVividToColour() {
        XCTAssertEqual(IconStyle.effective(preferred: .vivid, reduceMotion: true), .colour)
        XCTAssertFalse(
            IconStyle.effective(preferred: .vivid, reduceMotion: true).isAnimated,
            "nothing may still be animating once Reduce Motion is on"
        )
    }

    func testReduceMotionLeavesStillStylesAlone() {
        for style in [IconStyle.subtle, .colour] {
            XCTAssertEqual(
                IconStyle.effective(preferred: style, reduceMotion: true), style,
                "\(style) has no motion to reduce"
            )
        }
    }

    func testStylesAreUnchangedWithoutReduceMotion() {
        for style in IconStyle.allCases {
            XCTAssertEqual(IconStyle.effective(preferred: style, reduceMotion: false), style)
        }
    }

    func testEveryStyleHasItsOwnCopy() {
        XCTAssertEqual(Set(IconStyle.allCases.map(\.title)).count, IconStyle.allCases.count)
        XCTAssertEqual(
            Set(IconStyle.allCases.map(\.explanation)).count, IconStyle.allCases.count
        )
    }
}

/// The icon must be derived from the session state, never assumed.
///
/// Regression guard: `advanceFrame()` used to paint an active icon unconditionally, on the
/// assumption that a running animation timer implied a running session. A frame tick queued
/// just before the user turned off would land afterwards and repaint the lit eye over the
/// off one — leaving the icon stuck lit with nothing actually running.
final class IconStateTests: XCTestCase {
    func testOffWhenInactive() {
        XCTAssertEqual(
            StatusItemController.iconState(isActive: false, clamshellActive: false),
            .off
        )
    }

    func testStaysOffEvenIfClamshellFlagLingers() {
        XCTAssertEqual(
            StatusItemController.iconState(isActive: false, clamshellActive: true),
            .off,
            "an inactive session must never render as active, whatever else is set"
        )
    }

    func testActiveStates() {
        XCTAssertEqual(
            StatusItemController.iconState(isActive: true, clamshellActive: false),
            .on
        )
        XCTAssertEqual(
            StatusItemController.iconState(isActive: true, clamshellActive: true),
            .onClosedLid
        )
    }
}

final class DurationFormattingTests: XCTestCase {
    func testTagRoundTrip() {
        for duration in SessionDuration.presets {
            XCTAssertEqual(SessionDuration(tagValue: duration.tagValue), duration)
        }
    }

    func testIndefiniteUsesZeroTag() {
        XCTAssertEqual(SessionDuration.indefinite.tagValue, 0)
        XCTAssertEqual(SessionDuration(tagValue: 0), .indefinite)
    }

    func testCompactFormatting() {
        XCTAssertEqual(TimeFormatting.compact(45), "45s")
        XCTAssertEqual(TimeFormatting.compact(60 * 42), "42m")
        XCTAssertEqual(TimeFormatting.compact(3600 + 60 * 18), "1h 18m")
        XCTAssertEqual(TimeFormatting.compact(-5), "0s")
    }

    func testPresetTitles() {
        XCTAssertEqual(SessionDuration.seconds(900).title, "15 minutes")
        XCTAssertEqual(SessionDuration.seconds(3600).title, "1 hour")
        XCTAssertEqual(SessionDuration.seconds(7200).title, "2 hours")
        XCTAssertEqual(SessionDuration.indefinite.title, "Indefinitely")
    }
}
