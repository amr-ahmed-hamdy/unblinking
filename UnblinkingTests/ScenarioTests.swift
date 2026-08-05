import IOKit
import XCTest
@testable import Unblinking

/// End-to-end scenarios against the real system: real `caffeinate` processes, real
/// `pmset` output, real signals.
///
/// Tests that need root are grouped at the bottom and skipped unless
/// `UNBLINKING_PRIVILEGED_TESTS=1`, so an ordinary `xcodebuild test` never puts a password
/// dialog on screen.
@MainActor
final class ScenarioTests: XCTestCase {
    private var preferences: Preferences!
    private var suiteName: String!
    private var coordinator: WakeCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.amrhamdy.unblinking.scenarios.\(UUID().uuidString)"
        preferences = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        preferences.closedLidEnabled = false
        coordinator = WakeCoordinator(preferences: preferences)
    }

    override func tearDown() async throws {
        // Catch a leaked child in whichever test caused it, rather than as a mystery
        // process showing up in some later test's stray list.
        let child = coordinator?.caffeinateChildPID
        coordinator?.prepareForTermination()
        if let child {
            XCTAssertEqual(kill(child, 0), -1, "caffeinate \(child) survived tearDown")
        }
        coordinator = nil
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// The assertion types pmset reports for a given caffeinate pid.
    private func assertionTypes(forPID pid: pid_t) -> Set<String> {
        let output = Shell.run("/usr/bin/pmset", ["-g", "assertions"]).stdout
        var types: Set<String> = []
        for line in output.split(separator: "\n") where line.contains("pid \(pid)(caffeinate)") {
            let fields = line.split(separator: " ").map(String.init)
            // "... 00:00:01 PreventUserIdleSystemSleep named: "caffeinate ...""
            if let namedIndex = fields.firstIndex(of: "named:"), namedIndex > 0 {
                types.insert(fields[namedIndex - 1])
            }
        }
        return types
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 8,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: - Preferences map to real assertions

    func testDisplayPreferenceCreatesADisplayAssertion() async throws {
        preferences.preventDisplaySleep = true
        preferences.preventIdleSleep = false
        preferences.preventDiskSleep = false
        preferences.preventSystemSleepOnAC = false

        coordinator.turnOn(duration: .indefinite)
        let pid = try XCTUnwrap(coordinator.caffeinateChildPID)
        _ = await waitUntil { !self.assertionTypes(forPID: pid).isEmpty }

        XCTAssertTrue(
            assertionTypes(forPID: pid).contains("PreventUserIdleDisplaySleep"),
            "-d should hold a display assertion; got \(assertionTypes(forPID: pid))"
        )
    }

    func testIdlePreferenceCreatesASystemAssertion() async throws {
        preferences.preventDisplaySleep = false
        preferences.preventIdleSleep = true
        preferences.preventDiskSleep = false
        preferences.preventSystemSleepOnAC = false

        coordinator.turnOn(duration: .indefinite)
        let pid = try XCTUnwrap(coordinator.caffeinateChildPID)
        _ = await waitUntil { !self.assertionTypes(forPID: pid).isEmpty }

        let types = assertionTypes(forPID: pid)
        XCTAssertTrue(types.contains("PreventUserIdleSystemSleep"), "got \(types)")
        XCTAssertFalse(
            types.contains("PreventUserIdleDisplaySleep"),
            "display sleep was switched off, so no display assertion should be held"
        )
    }

    // MARK: - Session lifecycle

    func testTimedSessionExpiresAndReturnsToOff() async throws {
        coordinator.turnOn(duration: .seconds(2))
        XCTAssertTrue(coordinator.isActive)
        XCTAssertNotNil(coordinator.endsAt)
        let pid = try XCTUnwrap(coordinator.caffeinateChildPID)

        let wentIdle = await waitUntil(timeout: 15) { !self.coordinator.isActive }
        XCTAssertTrue(wentIdle, "the session should end itself when -t elapses")
        XCTAssertNil(coordinator.startedAt)
        XCTAssertNil(coordinator.endsAt)
        XCTAssertEqual(kill(pid, 0), -1, "the caffeinate child should be gone")
    }

    /// If something kills caffeinate behind the app's back, the menu bar must not keep
    /// claiming the Mac is awake, that is the exact confusion this app exists to end.
    func testExternallyKilledChildFlipsTheAppBackToOff() async throws {
        coordinator.turnOn(duration: .indefinite)
        let pid = try XCTUnwrap(coordinator.caffeinateChildPID)

        kill(pid, SIGKILL)

        let noticed = await waitUntil { !self.coordinator.isActive }
        XCTAssertTrue(noticed, "the app kept reporting 'awake' after its child died")
        XCTAssertNil(coordinator.caffeinateChildPID)
    }

    func testSessionCanBeRestartedAfterEnding() async throws {
        coordinator.turnOn(duration: .seconds(2))
        let firstPID = try XCTUnwrap(coordinator.caffeinateChildPID)
        _ = await waitUntil(timeout: 15) { !self.coordinator.isActive }

        coordinator.turnOn(duration: .indefinite)
        XCTAssertTrue(coordinator.isActive)
        let secondPID = try XCTUnwrap(coordinator.caffeinateChildPID)
        XCTAssertNotEqual(firstPID, secondPID)
        XCTAssertTrue(assertionTypes(forPID: secondPID).isEmpty == false)
    }

    func testChangingDurationReplacesTheSession() async throws {
        coordinator.turnOn(duration: .indefinite)
        XCTAssertNil(coordinator.endsAt)
        let firstPID = try XCTUnwrap(coordinator.caffeinateChildPID)

        coordinator.turnOff()
        coordinator.turnOn(duration: .seconds(3600))

        XCTAssertNotNil(coordinator.endsAt)
        XCTAssertEqual(kill(firstPID, 0), -1, "the previous child should not survive")
    }

    // MARK: - Stray processes

    func testExternalUnblinkingIsDetectedAndCanBeStopped() async throws {
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        external.arguments = ["-i", "-t", "60"]
        try external.run()
        defer { if external.isRunning { external.terminate() } }

        let strayPID = external.processIdentifier
        let spotted = await waitUntil {
            self.coordinator.refreshStrays()
            return self.coordinator.strays.contains { $0.pid == strayPID }
        }
        XCTAssertTrue(spotted, "an externally started caffeinate should be reported")

        let stray = try XCTUnwrap(coordinator.strays.first { $0.pid == strayPID })
        XCTAssertTrue(
            stray.command.contains("caffeinate"),
            "the menu shows the full command so the user can judge it: \(stray.command)"
        )

        coordinator.stopStray(stray)
        let stopped = await waitUntil { kill(strayPID, 0) == -1 }
        XCTAssertTrue(stopped, "stopping a stray should actually terminate it")
    }

    func testStrayListIsEmptyWhenNothingElseIsRunning() async throws {
        // Only meaningful if the machine happens to be quiet; skip rather than fail if
        // some other tool is legitimately holding an assertion.
        coordinator.refreshStrays()
        let others = coordinator.strays
        try XCTSkipUnless(others.isEmpty, "other caffeinate processes present: \(others)")

        coordinator.turnOn(duration: .indefinite)
        coordinator.refreshStrays()
        XCTAssertTrue(
            coordinator.strays.isEmpty,
            "the app's own child must never appear as a stray"
        )
    }

    // MARK: - Rapid toggling

    /// Flipping on and straight back off must settle as off and stay off.
    ///
    /// The reported symptom was the menu bar icon staying amber after a quick on/off, so
    /// this also waits past a few animation frames to catch anything that repaints late.
    func testRapidOnOffSettlesAsOff() async throws {
        for _ in 0..<5 {
            coordinator.turnOn(duration: .indefinite)
            coordinator.turnOff()
        }

        XCTAssertFalse(coordinator.isActive)
        XCTAssertNil(coordinator.caffeinateChildPID)
        XCTAssertEqual(
            StatusItemController.iconState(
                isActive: coordinator.isActive,
                clamshellActive: coordinator.clamshellActive
            ),
            .off
        )

        // Let any queued termination handlers land, then confirm nothing flipped back.
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(coordinator.isActive, "the session came back on by itself")
        XCTAssertNil(coordinator.caffeinateChildPID)
    }

    /// A stale termination handler from the previous run must not wipe out the new one.
    func testQuickOffThenOnKeepsTheNewChild() async throws {
        coordinator.turnOn(duration: .indefinite)
        let first = try XCTUnwrap(coordinator.caffeinateChildPID)

        coordinator.turnOff()
        coordinator.turnOn(duration: .indefinite)
        let second = try XCTUnwrap(coordinator.caffeinateChildPID)
        XCTAssertNotEqual(first, second)

        // The first child's handler is delivered asynchronously; give it time to arrive.
        try? await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertTrue(coordinator.isActive, "the old child's exit ended the new session")
        XCTAssertEqual(
            coordinator.caffeinateChildPID, second,
            "a stale termination handler cleared the current child"
        )
        XCTAssertEqual(kill(second, 0), 0, "the new child should still be running")
    }

    // MARK: - Changing duration mid-session

    /// Re-timing a live session must move its end, not silently store a preference for
    /// next time, which is what the Settings duration picker used to do.
    func testSettingDurationRetimesTheRunningSession() throws {
        coordinator.turnOn(duration: .indefinite)
        XCTAssertNil(coordinator.endsAt, "an indefinite session has no end")
        let started = try XCTUnwrap(coordinator.startedAt)

        coordinator.setDuration(.seconds(3600))

        let endsAt = try XCTUnwrap(coordinator.endsAt, "the session should now have an end")
        XCTAssertEqual(endsAt.timeIntervalSinceNow, 3600, accuracy: 5)
        XCTAssertEqual(preferences.defaultDuration, .seconds(3600))
        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(
            coordinator.startedAt, started,
            "re-timing is not a restart, elapsed must keep counting from the original start"
        )
    }

    func testSettingDurationBackToIndefiniteClearsTheEnd() throws {
        coordinator.turnOn(duration: .seconds(900))
        XCTAssertNotNil(coordinator.endsAt)

        coordinator.setDuration(.indefinite)
        XCTAssertNil(coordinator.endsAt)
        XCTAssertTrue(coordinator.isActive)
    }

    /// The caffeinate child bakes `-t` in at spawn, so re-timing has to replace it.
    /// Otherwise the old timeout would still fire at the old moment.
    func testRetimingReplacesTheCaffeinateChild() throws {
        coordinator.turnOn(duration: .seconds(900))
        let first = try XCTUnwrap(coordinator.caffeinateChildPID)

        coordinator.setDuration(.seconds(7200))
        let second = try XCTUnwrap(coordinator.caffeinateChildPID)

        XCTAssertNotEqual(first, second, "the old -t would still expire at the old time")
        XCTAssertEqual(kill(first, 0), -1, "the replaced child must not survive")
    }

    func testSettingDurationWhileOffOnlyStoresThePreference() {
        XCTAssertFalse(coordinator.isActive)
        coordinator.setDuration(.seconds(1800))

        XCTAssertEqual(preferences.defaultDuration, .seconds(1800))
        XCTAssertFalse(coordinator.isActive, "storing a preference must not start a session")
        XCTAssertNil(coordinator.caffeinateChildPID)
    }

    // MARK: - Battery policy

    /// A policy change must be applied at once, not deferred to the next power event.
    /// Needs the machine to actually be on battery, so it skips on AC.
    func testSwitchingPolicyWhileOnBatteryAppliesImmediately() async throws {
        try XCTSkipUnless(!PowerEnvironment.isOnACPower, "only meaningful on battery")

        coordinator.turnOn(duration: .indefinite)
        XCTAssertTrue(coordinator.isActive)

        // Without closed-lid mode held, the policy is a no-op by design, the assertion
        // layer alone can't flatten a machine the way disabled sleep can.
        coordinator.setBatteryPolicy(.offWhenUnplugged)
        XCTAssertTrue(
            coordinator.isActive,
            "battery policy should only govern closed-lid mode, not plain assertions"
        )
    }

    /// The regression that made the app look completely dead.
    ///
    /// With closed-lid mode switched on, the policy set to "off when unplugged", and the
    /// charger out, `turnOn` spawned caffeinate and then `evaluateBatteryPolicy` called
    /// `finishSession`, SIGTERMing it milliseconds later. Nothing was shown to the user:
    /// the eye never lit and clicking the icon appeared to do nothing at all.
    ///
    /// The policy governs the clamshell layer only. Plain assertions are harmless on
    /// battery, so the session must survive.
    func testTurningOnWhileUnpluggedKeepsTheSessionAlive() throws {
        try XCTSkipUnless(!PowerEnvironment.isOnACPower, "only meaningful on battery")

        preferences.closedLidEnabled = true
        preferences.batteryPolicy = .offWhenUnplugged

        coordinator.turnOn(duration: .indefinite)

        XCTAssertTrue(
            coordinator.isActive,
            "an unplugged battery policy must not end the whole session"
        )
        XCTAssertNotNil(
            coordinator.caffeinateChildPID,
            "caffeinate must still be running, the policy only governs closed-lid mode"
        )
        XCTAssertFalse(coordinator.clamshellActive, "the clamshell layer is what gets held back")
        XCTAssertTrue(
            coordinator.isClosedLidPausedByBattery,
            "the menu needs this to explain why the ticked setting is not in force"
        )
    }

    /// The gate is consulted *before* enabling, so a forbidden policy never sets and
    /// clears `SleepDisabled` in the same breath.
    func testBatteryPolicyGateMatchesThePolicy() throws {
        try XCTSkipUnless(!PowerEnvironment.isOnACPower, "only meaningful on battery")

        preferences.batteryPolicy = .never
        XCTAssertTrue(coordinator.batteryPolicyAllowsClamshell)

        preferences.batteryPolicy = .offWhenUnplugged
        XCTAssertFalse(coordinator.batteryPolicyAllowsClamshell)

        preferences.batteryPolicy = .offBelowThreshold
        let charge = try XCTUnwrap(PowerEnvironment.batteryPercentage)

        preferences.batteryThreshold = max(0, charge - 5)
        XCTAssertTrue(coordinator.batteryPolicyAllowsClamshell, "above the threshold")

        preferences.batteryThreshold = min(100, charge + 5)
        XCTAssertFalse(coordinator.batteryPolicyAllowsClamshell, "at or below the threshold")
    }

    func testBatteryPolicyChangeIsPersisted() {
        coordinator.setBatteryPolicy(.offBelowThreshold)
        XCTAssertEqual(preferences.batteryPolicy, .offBelowThreshold)

        coordinator.setBatteryThreshold(35)
        XCTAssertEqual(preferences.batteryThreshold, 35)

        coordinator.setBatteryPolicy(.never)
        XCTAssertEqual(preferences.batteryPolicy, .never)
    }

    // MARK: - Teardown

    func testPrepareForTerminationStopsEverything() async throws {
        coordinator.turnOn(duration: .indefinite)
        let pid = try XCTUnwrap(coordinator.caffeinateChildPID)

        coordinator.prepareForTermination()

        XCTAssertEqual(kill(pid, 0), -1, "quitting must not leave caffeinate running")
        XCTAssertFalse(preferences.weOwnSleepDisabled)
    }

    func testPrepareForTerminationIsSafeToCallTwice() {
        coordinator.turnOn(duration: .indefinite)
        coordinator.prepareForTermination()
        coordinator.prepareForTermination()
        XCTAssertFalse(coordinator.isActive)
    }

    /// Quitting must leave no trace of an active session behind, or a restart could show
    /// "awake" with nothing actually holding the Mac up.
    func testPrepareForTerminationClearsAllSessionState() {
        coordinator.turnOn(duration: .seconds(3600))
        XCTAssertTrue(coordinator.isActive)
        XCTAssertNotNil(coordinator.startedAt)
        XCTAssertNotNil(coordinator.endsAt)

        coordinator.prepareForTermination()

        XCTAssertFalse(coordinator.isActive)
        XCTAssertNil(coordinator.startedAt)
        XCTAssertNil(coordinator.endsAt)
        XCTAssertNil(coordinator.caffeinateChildPID)
    }

    /// Quitting is not the same as switching off, so the "turn on at launch" breadcrumb
    /// must survive it.
    func testQuittingWhileActiveStillRemembersItWasOn() {
        coordinator.turnOn(duration: .indefinite)
        XCTAssertTrue(preferences.lastStateWasOn)

        coordinator.prepareForTermination()
        XCTAssertTrue(
            preferences.lastStateWasOn,
            "quitting while awake should still restore on next launch"
        )

        coordinator.turnOn(duration: .indefinite)
        coordinator.turnOff()
        XCTAssertFalse(
            preferences.lastStateWasOn,
            "an explicit turn-off should not come back at launch"
        )
    }
}

/// Root-only paths. Run with:
///
///     UNBLINKING_PRIVILEGED_TESTS=1 xcodebuild -scheme Unblinking test
///
/// The first run shows one administrator prompt.
final class PrivilegedScenarioTests: XCTestCase {
    private func requirePrivilegedRun() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UNBLINKING_PRIVILEGED_TESTS"] == "1",
            "set UNBLINKING_PRIVILEGED_TESTS=1 to run tests that need an admin prompt"
        )
    }

    func testAuthorizationInstallsUnderALoadableName() throws {
        try requirePrivilegedRun()
        let runner = SudoersRunner()

        if !runner.isAuthorizationInstalled {
            try runner.installAuthorization()
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: SudoersRunner.ruleFilePath),
            "expected the rule at \(SudoersRunner.ruleFilePath)"
        )
        for legacy in SudoersRunner.legacyRuleFilePaths {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: legacy),
                "\(legacy) should have been cleaned up during install"
            )
        }
        XCTAssertTrue(
            runner.isAuthorizationInstalled,
            "sudo should now run the granted command without a password"
        )
    }

    func testSleepDisabledFlagTogglesBothWays() throws {
        try requirePrivilegedRun()
        let runner = SudoersRunner()
        try XCTSkipUnless(runner.isAuthorizationInstalled, "authorization not installed")

        let original = SleepDisabledFlag.read()
        defer { try? runner.setSleepDisabled(original) }

        try runner.setSleepDisabled(true)
        XCTAssertTrue(SleepDisabledFlag.read(), "pmset should report SleepDisabled 1")

        try runner.setSleepDisabled(false)
        XCTAssertFalse(SleepDisabledFlag.read(), "pmset should report SleepDisabled 0")
    }

    /// The grant must be exactly two commands. If this ever passes for something else,
    /// the rule has been widened.
    func testGrantDoesNotExtendToOtherCommands() throws {
        try requirePrivilegedRun()
        try XCTSkipUnless(SudoersRunner().isAuthorizationInstalled)

        XCTAssertFalse(
            Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-g"]).succeeded,
            "other pmset subcommands must still require a password"
        )
        XCTAssertFalse(
            Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "sleep", "0"]).succeeded,
            "changing other power settings must still require a password"
        )
        XCTAssertFalse(
            Shell.run("/usr/bin/sudo", ["-n", "/bin/ls", "/"]).succeeded,
            "unrelated commands must still require a password"
        )
    }

    /// What the Closed Lid settings tab tells the user must track the flag that actually
    /// decides it.
    func testLidCloseForecastFollowsTheSleepDisabledFlag() throws {
        try requirePrivilegedRun()
        let runner = SudoersRunner()
        try XCTSkipUnless(runner.isAuthorizationInstalled)

        let original = SleepDisabledFlag.read()
        defer { try? runner.setSleepDisabled(original) }

        try runner.setSleepDisabled(false)
        XCTAssertTrue(
            PowerEnvironment.lidCloseWouldSleep,
            "with sleep enabled, closing the lid should sleep"
        )

        try runner.setSleepDisabled(true)
        XCTAssertFalse(
            PowerEnvironment.lidCloseWouldSleep,
            "with SleepDisabled set, closing the lid must not sleep"
        )

        try runner.setSleepDisabled(original)
    }
}

/// Guards a wrong assumption this app was built on at first.
///
/// `AppleClamshellCausesSleep` reads like the perfect answer to "will closing the lid
/// sleep this Mac?", and the Closed Lid settings tab originally displayed it as exactly
/// that. Measured on macOS 26 it does not vary with `SleepDisabled` at all while the lid
/// is open, it describes the current clamshell state, not a future one. If this test ever
/// fails, the property gained real predictive behaviour and the UI could use it directly.
final class ClamshellPredictionTests: XCTestCase {
    func testRawClamshellPropertyIsNotAForecast() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UNBLINKING_PRIVILEGED_TESTS"] == "1",
            "set UNBLINKING_PRIVILEGED_TESTS=1 to run tests that need an admin prompt"
        )
        let runner = SudoersRunner()
        try XCTSkipUnless(runner.isAuthorizationInstalled)
        try XCTSkipUnless(
            PowerEnvironment.isLidClosed == false,
            "only meaningful with the lid open"
        )

        let original = SleepDisabledFlag.read()
        defer { try? runner.setSleepDisabled(original) }

        func rawProperty() -> Bool? {
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("IOPMrootDomain")
            )
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            return IORegistryEntryCreateCFProperty(
                service, "AppleClamshellCausesSleep" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? Bool
        }

        try runner.setSleepDisabled(false)
        let withSleepEnabled = rawProperty()

        try runner.setSleepDisabled(true)
        let withSleepDisabled = rawProperty()

        try runner.setSleepDisabled(original)

        XCTAssertEqual(
            withSleepEnabled, withSleepDisabled,
            "AppleClamshellCausesSleep changed with SleepDisabled, it may now be usable "
                + "as a forecast, so PowerEnvironment.lidCloseWouldSleep could read it"
        )
    }
}

/// What each battery policy actually *does* to a running session, including switching
/// into a policy while the machine is already in its triggering condition.
///
/// The privileged runner and the power source are both faked, so these cover unplugging,
/// plugging back in, and every charge level without root and without a real charger.
@MainActor
final class BatteryPolicyTransitionTests: XCTestCase {
    private final class FakeRunner: PrivilegedRunner, @unchecked Sendable {
        var isAuthorizationInstalled = true
        var sleepDisabled = false
        /// Every value the policy pushed to the system, in order.
        var writes: [Bool] = []

        func setSleepDisabled(_ disabled: Bool) throws {
            sleepDisabled = disabled
            writes.append(disabled)
        }
        func installAuthorization() throws {}
        func removeAuthorization() throws {}
    }

    private final class MutablePower: PowerSourceReading, @unchecked Sendable {
        var isOnACPower: Bool
        var batteryPercentage: Int?
        init(onAC: Bool, charge: Int?) {
            isOnACPower = onAC
            batteryPercentage = charge
        }
    }

    private var suiteName: String!
    private var preferences: Preferences!
    private var runner: FakeRunner!
    private var power: MutablePower!
    private var coordinator: WakeCoordinator!

    override func tearDown() async throws {
        coordinator?.prepareForTermination()
        coordinator = nil
        if let suiteName { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    /// Builds a running session with closed-lid mode switched on.
    private func start(
        policy: BatteryPolicy,
        threshold: Int = 20,
        onAC: Bool,
        charge: Int?
    ) {
        suiteName = "com.amrhamdy.unblinking.transitions.\(UUID().uuidString)"
        preferences = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        preferences.closedLidEnabled = true
        preferences.batteryPolicy = policy
        preferences.batteryThreshold = threshold

        runner = FakeRunner()
        power = MutablePower(onAC: onAC, charge: charge)
        coordinator = WakeCoordinator(
            preferences: preferences,
            clamshell: ClamshellController(runner: runner),
            power: power
        )
        coordinator.turnOn(duration: .indefinite)
    }

    // MARK: - "Never turn off automatically"

    /// Option 1 means exactly what it says, even at a critical charge.
    func testNeverKeepsClosedLidOnAtCriticalCharge() {
        start(policy: .never, onAC: false, charge: 2)

        XCTAssertTrue(coordinator.clamshellActive)
        XCTAssertTrue(runner.sleepDisabled)

        coordinator.evaluateBatteryPolicy()
        XCTAssertTrue(coordinator.clamshellActive, "\"never\" must never withdraw it")
        XCTAssertTrue(runner.sleepDisabled)
        XCTAssertFalse(coordinator.isClosedLidPausedByBattery)
    }

    // MARK: - "Turn off when unplugged from power"

    /// Option 2, the case the user hit: switch to it while already unplugged and it must
    /// take effect at once, not wait for the next charger event.
    func testSwitchingToUnpluggedPolicyWhileUnpluggedWithdrawsAtOnce() {
        start(policy: .never, onAC: false, charge: 80)
        XCTAssertTrue(coordinator.clamshellActive)

        coordinator.setBatteryPolicy(.offWhenUnplugged)

        XCTAssertFalse(coordinator.clamshellActive, "must withdraw immediately on switching")
        XCTAssertFalse(runner.sleepDisabled)
        XCTAssertEqual(runner.writes, [true, false])
        XCTAssertTrue(coordinator.isActive, "only closed-lid mode is withdrawn")
        XCTAssertNotNil(coordinator.caffeinateChildPID)
        XCTAssertTrue(coordinator.isClosedLidPausedByBattery, "the menu must be able to say why")
    }

    /// Unplugging mid-session does the same thing.
    func testUnpluggingMidSessionWithdrawsClosedLid() {
        start(policy: .offWhenUnplugged, onAC: true, charge: 90)
        XCTAssertTrue(coordinator.clamshellActive)

        power.isOnACPower = false
        coordinator.evaluateBatteryPolicy()

        XCTAssertFalse(coordinator.clamshellActive)
        XCTAssertTrue(coordinator.isActive)
    }

    /// And plugging back in restores it, which is what "only holds while the charger is
    /// connected" promises.
    func testPluggingBackInRestoresClosedLid() {
        start(policy: .offWhenUnplugged, onAC: true, charge: 90)
        power.isOnACPower = false
        coordinator.evaluateBatteryPolicy()
        XCTAssertFalse(coordinator.clamshellActive)

        power.isOnACPower = true
        coordinator.evaluateBatteryPolicy()

        XCTAssertTrue(coordinator.clamshellActive, "reconnecting the charger restores it")
        XCTAssertTrue(runner.sleepDisabled)
        XCTAssertFalse(coordinator.isClosedLidPausedByBattery)
    }

    // MARK: - "Turn off below a battery level"

    /// Option 3, switched into while already under the threshold.
    func testSwitchingToThresholdPolicyBelowTheThresholdWithdrawsAtOnce() {
        start(policy: .never, onAC: false, charge: 15)
        XCTAssertTrue(coordinator.clamshellActive)

        preferences.batteryThreshold = 20
        coordinator.setBatteryPolicy(.offBelowThreshold)

        XCTAssertFalse(coordinator.clamshellActive)
        XCTAssertTrue(coordinator.isActive)
        XCTAssertTrue(coordinator.isClosedLidPausedByBattery)
    }

    /// Draining past the threshold withdraws it without any user action.
    func testDrainingPastTheThresholdWithdrawsClosedLid() {
        start(policy: .offBelowThreshold, threshold: 20, onAC: false, charge: 25)
        XCTAssertTrue(coordinator.clamshellActive)

        power.batteryPercentage = 20
        coordinator.evaluateBatteryPolicy()

        XCTAssertFalse(coordinator.clamshellActive, "at the threshold counts as below")
    }

    /// Editing the threshold re-evaluates in both directions.
    func testThresholdEditsApplyImmediatelyBothWays() {
        start(policy: .offBelowThreshold, threshold: 20, onAC: false, charge: 30)
        XCTAssertTrue(coordinator.clamshellActive)

        coordinator.setBatteryThreshold(35)
        XCTAssertFalse(coordinator.clamshellActive, "raising past the charge withdraws it")

        coordinator.setBatteryThreshold(10)
        XCTAssertTrue(coordinator.clamshellActive, "lowering below the charge restores it")
    }

    // MARK: - Turning on inside a forbidden condition

    /// The gate runs before the layer is enabled, so a forbidden policy costs no
    /// privileged call at all rather than setting the flag and clearing it again.
    func testTurningOnWhileForbiddenNeverTouchesTheSystemFlag() {
        start(policy: .offBelowThreshold, threshold: 20, onAC: false, charge: 10)

        XCTAssertTrue(coordinator.isActive)
        XCTAssertNotNil(coordinator.caffeinateChildPID)
        XCTAssertFalse(coordinator.clamshellActive)
        XCTAssertTrue(runner.writes.isEmpty, "no set-then-clear churn on a system-wide flag")
        XCTAssertTrue(coordinator.isClosedLidPausedByBattery)
    }

    /// Ticking the lid setting while the policy forbids it must not engage it either.
    func testEnablingClosedLidWhileForbiddenDoesNotEngageIt() {
        start(policy: .offWhenUnplugged, onAC: false, charge: 50)
        XCTAssertFalse(coordinator.clamshellActive)

        coordinator.setClosedLidEnabled(true)

        XCTAssertFalse(coordinator.clamshellActive)
        XCTAssertTrue(runner.writes.isEmpty)
    }
}
