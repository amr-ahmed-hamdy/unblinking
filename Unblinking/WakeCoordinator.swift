import AppKit
import UserNotifications

/// Single source of truth for "is the Mac being kept awake, and how".
///
/// Two independent layers sit underneath:
///   1. `CaffeineProcess`  , blocks idle/display/disk sleep. No privileges.
///   2. `ClamshellController`, blocks lid-close sleep. Needs root, system-wide, sticky.
///
/// Layer 2 is the dangerous one: `SleepDisabled` outlives the app and even a reboot, so
/// teardown is handled on every exit path plus a recovery check at next launch.
@MainActor
final class WakeCoordinator: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var clamshellActive = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var endsAt: Date?
    @Published private(set) var strays: [StrayProcess] = []
    @Published private(set) var isAuthorizingClosedLid = false

    /// Fired on any state change so the status item can refresh without Combine.
    var onStateChange: (() -> Void)?

    private let caffeine = CaffeineProcess()
    private let clamshell: ClamshellController
    private let preferences: Preferences
    private var expiryTimer: Timer?
    private var powerObserver: PowerSourceObserver?
    private var hasWarnedOnBattery = false

    init(preferences: Preferences = .shared, clamshell: ClamshellController? = nil) {
        self.preferences = preferences
        self.clamshell = clamshell ?? ClamshellController()

        caffeine.onUnexpectedExit = { [weak self] in
            // caffeinate exited by itself: -t elapsed, or something killed it. Whatever
            // the reason, the UI must stop claiming the Mac is awake.
            self?.finishSession(clearClamshell: true)
        }
    }

    // MARK: - Lifecycle

    func bootstrap() {
        performLaunchRecovery()

        powerObserver = PowerSourceObserver { [weak self] in
            Task { @MainActor in self?.evaluateBatteryPolicy() }
        }

        refreshStrays()

        if preferences.restoreStateAtLaunch && preferences.lastStateWasOn {
            turnOn(duration: preferences.defaultDuration)
        }
    }

    /// Clears everything this app is responsible for. Safe to call more than once.
    ///
    /// Deliberately leaves `lastStateWasOn` alone: quitting while active is not the same
    /// as switching off, and "Turn on automatically at launch" depends on that difference.
    func prepareForTermination() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        caffeine.stop()

        if clamshellActive || preferences.weOwnSleepDisabled {
            try? clamshell.setEnabled(false)
            preferences.weOwnSleepDisabled = false
            clamshellActive = false
        }

        // Reset the published state too. Leaving isActive set would mean a glowing eye
        // with no caffeinate behind it, exactly the phantom state this app exists to
        // prevent, for anything that keeps running after this call.
        isActive = false
        startedAt = nil
        endsAt = nil
        notifyStateChange()
    }

    /// `SleepDisabled` persists across crashes and reboots, so a launch that finds it set
    /// has to work out who set it.
    private func performLaunchRecovery() {
        guard clamshell.isSleepDisabled else {
            // Nothing is disabled; drop any stale breadcrumb.
            preferences.weOwnSleepDisabled = false
            return
        }

        if preferences.weOwnSleepDisabled {
            // We set it and never got to clean up, force quit, crash, or power loss.
            // Restore normal sleep without bothering the user.
            try? clamshell.setEnabled(false)
            preferences.weOwnSleepDisabled = false
        } else {
            presentStaleSleepAlert()
        }
    }

    private func presentStaleSleepAlert() {
        let alert = NSAlert()
        alert.messageText = "This Mac is set to never sleep"
        alert.informativeText = """
            The system-wide "disable sleep" setting is currently on, but Unblinking didn't \
            turn it on. Something else did: another app, or a manual \
            "sudo pmset -a disablesleep 1" in Terminal.

            While it's on, this Mac won't sleep even when you close the lid.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore Normal Sleep")
        alert.addButton(withTitle: "Leave It On")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try clamshell.setEnabled(false)
        } catch PrivilegeError.notAuthorized {
            requestAuthorization { [weak self] in
                try? self?.clamshell.setEnabled(false)
            }
        } catch {
            presentError(error)
        }
    }

    // MARK: - Toggling

    func toggle() {
        if isActive {
            turnOff()
        } else {
            turnOn(duration: preferences.defaultDuration)
        }
    }

    func turnOn(duration: SessionDuration) {
        guard !isActive else { return }

        let options = CaffeineProcess.Options(
            display: preferences.preventDisplaySleep,
            idle: preferences.preventIdleSleep,
            disk: preferences.preventDiskSleep,
            systemOnAC: preferences.preventSystemSleepOnAC
        )

        do {
            try caffeine.start(options: options, duration: duration)
        } catch {
            presentError(error)
            return
        }

        isActive = true
        startedAt = Date()
        endsAt = duration.secondsValue.map { Date().addingTimeInterval(TimeInterval($0)) }
        preferences.lastStateWasOn = true
        hasWarnedOnBattery = false

        scheduleExpiry()
        if preferences.closedLidEnabled && batteryPolicyAllowsClamshell {
            enableClamshell()
        }

        refreshStrays()
        notifyStateChange()
    }

    func turnOff() {
        finishSession(clearClamshell: true)
    }

    /// Changes how long the current session has left, and remembers the choice for next
    /// time. Safe to call when nothing is running, it just stores the preference.
    ///
    /// The caffeinate child bakes `-t` in at spawn, so the assertion layer genuinely has
    /// to be replaced. The clamshell layer does not: cycling `SleepDisabled` would restore
    /// system sleep for a moment and cost two more privileged calls for no reason.
    func setDuration(_ duration: SessionDuration) {
        preferences.defaultDuration = duration
        guard isActive else { return }

        let options = CaffeineProcess.Options(
            display: preferences.preventDisplaySleep,
            idle: preferences.preventIdleSleep,
            disk: preferences.preventDiskSleep,
            systemOnAC: preferences.preventSystemSleepOnAC
        )

        do {
            // start() stops the previous child first.
            try caffeine.start(options: options, duration: duration)
        } catch {
            presentError(error)
            return
        }

        // The session didn't restart, it was re-timed, so "elapsed" keeps counting from
        // the original start, while "remaining" measures from now.
        endsAt = duration.secondsValue.map { Date().addingTimeInterval(TimeInterval($0)) }
        scheduleExpiry()
        notifyStateChange()
    }

    private func finishSession(clearClamshell: Bool) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        caffeine.stop()

        isActive = false
        startedAt = nil
        endsAt = nil
        preferences.lastStateWasOn = false

        if clearClamshell && (clamshellActive || preferences.weOwnSleepDisabled) {
            disableClamshell()
        }

        refreshStrays()
        notifyStateChange()
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        guard let endsAt else { return }

        // caffeinate's own -t already drops the assertion on time. This timer exists to
        // tear down the *clamshell* layer at the same moment, which -t knows nothing about.
        let timer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishSession(clearClamshell: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    // MARK: - Closed-lid mode

    /// Toggles closed-lid mode. Takes effect immediately if a session is running.
    func setClosedLidEnabled(_ enabled: Bool) {
        preferences.closedLidEnabled = enabled

        if enabled {
            if isActive && batteryPolicyAllowsClamshell { enableClamshell() }
        } else {
            disableClamshell()
        }
        notifyStateChange()
    }

    private func enableClamshell() {
        // Check before trying, rather than relying on the attempt to fail. A grant left
        // over from an older name still works, so "just try it" would silently keep using
        // the stale rule forever; asking first lets the install path migrate it.
        guard clamshell.isAuthorized else {
            requestAuthorization { [weak self] in self?.enableClamshell() }
            return
        }

        do {
            // Breadcrumb first: if we're killed between here and the flag actually being
            // set, the next launch clears a flag we don't own, harmless. The reverse
            // order could leave the flag set with nobody claiming it.
            preferences.weOwnSleepDisabled = true
            try clamshell.setEnabled(true)
            clamshellActive = true
            evaluateBatteryPolicy()
        } catch PrivilegeError.notAuthorized {
            preferences.weOwnSleepDisabled = false
            requestAuthorization { [weak self] in
                self?.enableClamshell()
            }
        } catch {
            preferences.weOwnSleepDisabled = false
            presentError(error)
        }
        notifyStateChange()
    }

    private func disableClamshell() {
        do {
            try clamshell.setEnabled(false)
            preferences.weOwnSleepDisabled = false
            clamshellActive = false
        } catch PrivilegeError.notAuthorized {
            // Can't clear it silently, tell the user rather than leaving them believing
            // sleep is back to normal when it isn't.
            requestAuthorization { [weak self] in
                self?.disableClamshell()
            }
        } catch {
            presentError(error)
        }
        notifyStateChange()
    }

    /// Runs the one-time administrator prompt, then retries whatever needed it.
    private func requestAuthorization(then retry: @escaping () -> Void) {
        guard !isAuthorizingClosedLid else { return }
        isAuthorizingClosedLid = true
        notifyStateChange()

        Task { [weak self] in
            let outcome: Result<Void, Error> = await Task.detached {
                do {
                    try SudoersRunner().installAuthorization()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            self.isAuthorizingClosedLid = false

            switch outcome {
            case .success:
                retry()
            case .failure(PrivilegeError.userCancelled):
                // The user declined. Closed-lid mode simply stays off; the assertion
                // layer carries on working.
                self.preferences.closedLidEnabled = false
            case .failure(let error):
                self.presentError(error)
                self.preferences.closedLidEnabled = false
            }
            self.notifyStateChange()
        }
    }

    func removeClosedLidAuthorization() {
        Task { [weak self] in
            let outcome: Result<Void, Error> = await Task.detached {
                do {
                    try SudoersRunner().removeAuthorization()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            if case .failure(let error) = outcome,
               case PrivilegeError.userCancelled = error {
                return
            }
            if case .failure(let error) = outcome {
                self.presentError(error)
            }
            self.notifyStateChange()
        }
    }

    var isClosedLidAuthorized: Bool { clamshell.isAuthorized }

    // MARK: - Battery

    /// Changing the policy has to re-evaluate straight away.
    ///
    /// Otherwise picking "Turn off when unplugged" while already running on battery does
    /// nothing at all until the next time the charger is plugged in and pulled out, the
    /// one moment the setting is least likely to be what the user wanted.
    func setBatteryPolicy(_ policy: BatteryPolicy) {
        preferences.batteryPolicy = policy
        hasWarnedOnBattery = false
        evaluateBatteryPolicy()
        notifyStateChange()
    }

    func setBatteryThreshold(_ threshold: Int) {
        preferences.batteryThreshold = threshold
        evaluateBatteryPolicy()
        notifyStateChange()
    }

    /// Whether the battery policy permits closed-lid mode *right now*.
    ///
    /// Consulted before the layer is enabled as well as after, so a policy that forbids
    /// it never causes `SleepDisabled` to be set and cleared again in the same breath,
    /// which cost two privileged calls and briefly changed a system-wide setting for
    /// nothing.
    var batteryPolicyAllowsClamshell: Bool {
        if PowerEnvironment.isOnACPower { return true }

        switch preferences.batteryPolicy {
        case .never:
            return true
        case .offWhenUnplugged:
            return false
        case .offBelowThreshold:
            guard let percentage = PowerEnvironment.batteryPercentage else { return true }
            return percentage > preferences.batteryThreshold
        }
    }

    /// True when closed-lid mode is switched on but the battery policy is holding it
    /// back, so the menu can say so rather than appearing to ignore the setting.
    var isClosedLidPausedByBattery: Bool {
        isActive && preferences.closedLidEnabled && !clamshellActive
            && !batteryPolicyAllowsClamshell
    }

    /// Applies the configured battery policy. Default is `.never`, which only warns.
    private func evaluateBatteryPolicy() {
        guard isActive, preferences.closedLidEnabled else { return }

        let onAC = PowerEnvironment.isOnACPower
        if onAC { hasWarnedOnBattery = false }

        guard batteryPolicyAllowsClamshell else {
            // Only the clamshell layer is at issue on battery. The caffeinate assertions
            // cost nothing extra there and are exactly what the user asked for, so the
            // session stays up.
            //
            // This used to call `finishSession`, which ended everything. With the policy
            // set to "off when unplugged" and the charger out, turning the app on spawned
            // caffeinate and then SIGTERMed it within milliseconds: the eye never lit, no
            // error was shown, and the app looked completely broken.
            if clamshellActive { disableClamshell() }
            return
        }

        // Back within policy, charger reconnected or charge topped back up. Restore the
        // layer the user asked for, but never prompt for it: an unexpected password
        // dialog on plugging in would be its own bug.
        if !clamshellActive && clamshell.isAuthorized { enableClamshell() }

        // "Never" is allowed to keep running on battery by design, so make it visible.
        if !onAC, preferences.batteryPolicy == .never, clamshellActive, !hasWarnedOnBattery {
            hasWarnedOnBattery = true
            postBatteryWarning()
        }
    }

    /// Best-effort: notifications are a nicety here, and the menu bar warning is the
    /// signal that always shows.
    private func postBatteryWarning() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Running on battery with sleep disabled"
            content.body = "This Mac won't sleep, even with the lid closed. "
                + "It will keep draining until you turn Unblinking off."

            let request = UNNotificationRequest(
                identifier: "com.amrhamdy.unblinking.battery",
                content: content,
                trigger: nil
            )
            // Fetch the centre again rather than capturing it: UNUserNotificationCenter
            // isn't Sendable, and this closure runs off the main actor.
            UNUserNotificationCenter.current().add(request)
        }
    }

    var isOnBatteryWithSleepDisabled: Bool {
        clamshellActive && !PowerEnvironment.isOnACPower
    }

    /// pid of the `caffeinate` child, when one is running. Useful for diagnostics and for
    /// telling our own process apart from strays.
    var caffeinateChildPID: pid_t? { caffeine.childPID }

    // MARK: - Stray processes

    func refreshStrays() {
        strays = StrayProcessWatcher.find(excluding: caffeine.childPID)
    }

    func stopStray(_ process: StrayProcess) {
        StrayProcessWatcher.stop(process)
        refreshStrays()
        notifyStateChange()
    }

    // MARK: - Helpers

    private func notifyStateChange() {
        objectWillChange.send()
        onStateChange?()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Unblinking ran into a problem"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
