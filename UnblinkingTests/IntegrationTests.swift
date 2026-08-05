import XCTest
@testable import Unblinking

/// Exercises the real assertion layer against the real system: actual `caffeinate`
/// processes, actual `pmset` output. Nothing here needs privileges, and closed-lid mode is
/// left switched off throughout so no password prompt can appear mid-test.
@MainActor
final class AssertionLifecycleTests: XCTestCase {
    private var preferences: Preferences!
    private var suiteName: String!
    private var coordinator: WakeCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        // A throwaway defaults suite, so running tests never touches real settings.
        suiteName = "com.amrhamdy.unblinking.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        preferences = Preferences(defaults: defaults)
        preferences.closedLidEnabled = false
        preferences.preventDisplaySleep = false
        preferences.preventIdleSleep = true
        coordinator = WakeCoordinator(preferences: preferences)
    }

    override func tearDown() async throws {
        coordinator?.prepareForTermination()
        coordinator = nil
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func assertionsOutput() -> String {
        Shell.run("/usr/bin/pmset", ["-g", "assertions"]).stdout
    }

    func testTurningOnCreatesARealPowerAssertion() throws {
        XCTAssertFalse(coordinator.isActive)

        coordinator.turnOn(duration: .seconds(60))
        XCTAssertTrue(coordinator.isActive)

        let pid = try XCTUnwrap(
            coordinator.caffeinateChildPID,
            "turnOn should have spawned a caffeinate child"
        )

        // pmset lists assertions by owning process: "pid 1234(caffeinate): [...]".
        // Match our own child so other caffeinate users on the machine can't fake a pass.
        XCTAssertTrue(
            assertionsOutput().contains("pid \(pid)(caffeinate)"),
            "Expected an assertion owned by pid \(pid)"
        )

        coordinator.turnOff()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertNil(coordinator.caffeinateChildPID)

        XCTAssertFalse(
            assertionsOutput().contains("pid \(pid)(caffeinate)"),
            "The assertion should be gone once the session ends"
        )
    }

    func testTurningOffLeavesNoProcessBehind() throws {
        coordinator.turnOn(duration: .indefinite)
        let pid = try XCTUnwrap(coordinator.caffeinateChildPID)

        coordinator.turnOff()

        // kill(pid, 0) succeeds only while the process still exists.
        XCTAssertEqual(kill(pid, 0), -1, "caffeinate process \(pid) outlived the session")
    }

    func testTogglingIsIdempotent() {
        coordinator.turnOn(duration: .indefinite)
        let firstPID = coordinator.caffeinateChildPID

        // A second turnOn must not spawn a competing child.
        coordinator.turnOn(duration: .indefinite)
        XCTAssertEqual(coordinator.caffeinateChildPID, firstPID)

        coordinator.turnOff()
        coordinator.turnOff()
        XCTAssertFalse(coordinator.isActive)
    }

    func testOurOwnChildIsNotReportedAsAStrayProcess() throws {
        coordinator.turnOn(duration: .indefinite)
        let pid = try XCTUnwrap(coordinator.caffeinateChildPID)

        coordinator.refreshStrays()
        XCTAssertFalse(
            coordinator.strays.contains { $0.pid == pid },
            "The app's own caffeinate must never be flagged as a stray"
        )
    }
}

/// The orphan guarantee rests entirely on `caffeinate -w` behaving as documented, so
/// verify that against the real binary rather than assuming it.
final class WatchdogBehaviourTests: XCTestCase {
    func testUnblinkingExitsWhenTheWatchedProcessDies() throws {
        // Stand-in for the app: something with a pid that we can kill on cue.
        let watched = Process()
        watched.executableURL = URL(fileURLWithPath: "/bin/sleep")
        watched.arguments = ["30"]
        try watched.run()

        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caffeinate.arguments = ["-i", "-w", String(watched.processIdentifier)]
        try caffeinate.run()

        XCTAssertTrue(caffeinate.isRunning)

        // Simulate the app being force-killed.
        kill(watched.processIdentifier, SIGKILL)
        watched.waitUntilExit()

        let deadline = Date().addingTimeInterval(10)
        while caffeinate.isRunning && Date() < deadline {
            usleep(50_000)
        }

        XCTAssertFalse(
            caffeinate.isRunning,
            "caffeinate -w should exit once the watched pid dies. That is what stops a "
                + "crashed app leaving an orphan holding the system awake"
        )

        if caffeinate.isRunning { caffeinate.terminate() }
    }
}
