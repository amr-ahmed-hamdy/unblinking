import AppKit
import Combine

/// The menu bar item: icon, click routing, and menu.
///
/// Built on `NSStatusItem` rather than SwiftUI's `MenuBarExtra` for two reasons.
/// `MenuBarExtra` opens its content on every click, so single-click-to-toggle is
/// impossible, and its label is snapshotted rather than animated.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let coordinator: WakeCoordinator
    private let preferences: Preferences

    private var animationTimer: Timer?
    private var tickTimer: Timer?
    private var animationFrame = 0
    private var screensAsleep = false
    private var preferenceObserver: AnyCancellable?

    var onOpenSettings: (() -> Void)?

    init(coordinator: WakeCoordinator, preferences: Preferences = .shared) {
        self.coordinator = coordinator
        self.preferences = preferences
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        coordinator.onStateChange = { [weak self] in
            self?.refresh()
        }

        // Appearance settings change the menu bar item without any wake-state change, and
        // nothing else would repaint it. With Vivid the animation timer happened to mask
        // this, it repaints constantly, but Subtle and Colour run no timer at all, so
        // switching style or toggling the clock left the old icon on screen until the next
        // toggle.
        //
        // `objectWillChange` fires *before* the property is updated, so hop a runloop turn
        // before reading it.
        preferenceObserver = preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        refresh()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Clicks

    enum ClickAction {
        case toggle
        case showMenu
    }

    /// Pure, so the routing can be pinned in tests.
    ///
    /// A nil event means the press did not come from the mouse, VoiceOver and other
    /// assistive presses arrive with no `NSApp.currentEvent`. Those must map to the
    /// primary action rather than being dropped, which is what an earlier
    /// `guard let event else { return }` did: the status item was simply dead to
    /// assistive technology.
    nonisolated static func action(
        eventType: NSEvent.EventType?,
        modifiers: NSEvent.ModifierFlags
    ) -> ClickAction {
        if eventType == .rightMouseUp { return .showMenu }
        if modifiers.contains(.control) { return .showMenu }
        return .toggle
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        switch Self.action(
            eventType: event?.type,
            modifiers: event?.modifierFlags ?? []
        ) {
        case .toggle:
            coordinator.toggle()
        case .showMenu:
            showMenu()
        }
    }

    private func showMenu() {
        coordinator.refreshStrays()

        let menu = buildMenu()
        menu.delegate = self

        // Attaching the menu makes the next click open it; detaching immediately
        // afterwards keeps left-click behaving as a plain toggle.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let toggle = NSMenuItem(
            title: coordinator.isActive ? "Turn Off" : "Turn On",
            action: #selector(toggleFromMenu),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let durationItem = NSMenuItem(title: "Duration", action: nil, keyEquivalent: "")
        let durationMenu = NSMenu()
        for duration in SessionDuration.presets {
            let item = NSMenuItem(
                title: duration.title,
                action: #selector(startWithDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = duration.tagValue
            item.state = (duration == preferences.defaultDuration) ? .on : .off
            durationMenu.addItem(item)
        }
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)

        let lidItem = NSMenuItem(
            title: "Keep Awake with the Lid Closed",
            action: #selector(toggleClosedLid),
            keyEquivalent: ""
        )
        lidItem.target = self
        lidItem.state = preferences.closedLidEnabled ? .on : .off
        if coordinator.isAuthorizingClosedLid {
            lidItem.title = "Keep Awake with the Lid Closed (waiting for your password…)"
            lidItem.isEnabled = false
        }
        menu.addItem(lidItem)

        addWarnings(to: menu)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Unblinking", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func addWarnings(to menu: NSMenu) {
        var addedSeparator = false
        func separatorIfNeeded() {
            guard !addedSeparator else { return }
            menu.addItem(.separator())
            addedSeparator = true
        }

        if coordinator.isOnBatteryWithSleepDisabled {
            separatorIfNeeded()
            let battery = PowerEnvironment.batteryPercentage.map { " (\($0)%)" } ?? ""
            let warning = NSMenuItem(
                title: "⚠ On battery\(battery), this Mac will not sleep",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
        }

        guard !coordinator.strays.isEmpty else { return }
        separatorIfNeeded()

        let count = coordinator.strays.count
        let strayItem = NSMenuItem(
            title: "⚠ \(count) caffeinate process\(count == 1 ? "" : "es") not started by Unblinking",
            action: nil,
            keyEquivalent: ""
        )
        let strayMenu = NSMenu()

        let explanation = NSMenuItem(
            title: "Started by something else, stop only what you recognise.",
            action: nil,
            keyEquivalent: ""
        )
        explanation.isEnabled = false
        strayMenu.addItem(explanation)
        strayMenu.addItem(.separator())

        for stray in coordinator.strays {
            let item = NSMenuItem(
                title: "PID \(stray.pid): \(stray.command)",
                action: #selector(stopStray(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(stray.pid)
            strayMenu.addItem(item)
        }

        strayItem.submenu = strayMenu
        menu.addItem(strayItem)
    }

    private var statusLine: String {
        guard coordinator.isActive, let startedAt = coordinator.startedAt else {
            return "Off, this Mac sleeps normally"
        }

        let suffix: String
        if let endsAt = coordinator.endsAt {
            suffix = "\(TimeFormatting.compact(endsAt.timeIntervalSinceNow)) remaining"
        } else {
            suffix = "\(TimeFormatting.compact(-startedAt.timeIntervalSinceNow)) elapsed"
        }

        return coordinator.clamshellActive
            ? "Awake with the lid closed, \(suffix)"
            : "Awake, \(suffix)"
    }

    // MARK: - Actions

    @objc private func toggleFromMenu() {
        coordinator.toggle()
    }

    @objc private func startWithDuration(_ sender: NSMenuItem) {
        let duration = SessionDuration(tagValue: sender.tag)
        if coordinator.isActive {
            // Re-time in place rather than turnOff/turnOn: a full restart would tear down
            // and re-establish closed-lid mode, briefly restoring system sleep.
            coordinator.setDuration(duration)
        } else {
            preferences.defaultDuration = duration
            coordinator.turnOn(duration: duration)
        }
    }

    @objc private func toggleClosedLid() {
        coordinator.setClosedLidEnabled(!preferences.closedLidEnabled)
    }

    @objc private func stopStray(_ sender: NSMenuItem) {
        guard let stray = coordinator.strays.first(where: { Int($0.pid) == sender.tag })
        else { return }
        coordinator.stopStray(stray)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Appearance

    /// Pure, so the "which icon" decision is testable and can't diverge between the two
    /// places that paint the button.
    nonisolated static func iconState(
        isActive: Bool,
        clamshellActive: Bool
    ) -> EyeIcon.State {
        guard isActive else { return .off }
        return clamshellActive ? .onClosedLid : .on
    }

    func refresh() {
        guard let button = statusItem.button else { return }

        let state = Self.iconState(
            isActive: coordinator.isActive,
            clamshellActive: coordinator.clamshellActive
        )

        button.image = EyeIcon.image(style: effectiveStyle, state: state, frame: animationFrame)
        button.toolTip = tooltip

        let title = menuBarTitle
        if title.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        } else {
            button.imagePosition = .imageLeft
            button.attributedTitle = NSAttributedString(
                string: " \(title)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                ]
            )
        }

        button.setAccessibilityLabel(tooltip)
        syncTimers()
    }

    private var menuBarTitle: String {
        guard preferences.showTimeInMenuBar, coordinator.isActive else { return "" }

        switch preferences.timeDisplay {
        case .elapsed:
            guard let startedAt = coordinator.startedAt else { return "" }
            return TimeFormatting.compact(-startedAt.timeIntervalSinceNow)
        case .remaining:
            guard let endsAt = coordinator.endsAt else { return "∞" }
            return TimeFormatting.compact(endsAt.timeIntervalSinceNow)
        }
    }

    private var tooltip: String {
        guard coordinator.isActive else { return "Unblinking, off. Click to keep this Mac awake." }
        return coordinator.clamshellActive
            ? "Unblinking, awake, including when the lid is closed. Click to turn off."
            : "Unblinking, awake. Click to turn off."
    }

    // MARK: - Timers

    /// The chosen style, after Reduce Motion has had its say.
    private var effectiveStyle: IconStyle {
        IconStyle.effective(
            preferred: preferences.iconStyle,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func syncTimers() {
        let shouldAnimate = coordinator.isActive
            && effectiveStyle.isAnimated
            && !screensAsleep

        if shouldAnimate {
            if animationTimer == nil {
                // target/selector rather than a block: the block form had to hop through
                // `Task { @MainActor in … }`, and a tick queued just before the session
                // ended would land afterwards and repaint the active icon over the off
                // one. Selector-based timers fire synchronously on the run loop, so no
                // such stale tick can exist.
                let timer = Timer(
                    timeInterval: 1.0 / EyeIcon.framesPerSecond,
                    target: self,
                    selector: #selector(animationTick),
                    userInfo: nil,
                    repeats: true
                )
                // .common keeps the glow breathing while a menu is open.
                RunLoop.main.add(timer, forMode: .common)
                animationTimer = timer
            }
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
            // Park on a lit frame rather than the dimmest one, so a static icon still
            // reads as active.
            animationFrame = EyeIcon.staticFrame
            if let button = statusItem.button, coordinator.isActive {
                let state: EyeIcon.State = coordinator.clamshellActive ? .onClosedLid : .on
                button.image = EyeIcon.image(
                    style: effectiveStyle, state: state, frame: animationFrame
                )
            }
        }

        let needsTick = coordinator.isActive && preferences.showTimeInMenuBar
        if needsTick {
            if tickTimer == nil {
                let timer = Timer(
                    timeInterval: 1,
                    target: self,
                    selector: #selector(clockTick),
                    userInfo: nil,
                    repeats: true
                )
                RunLoop.main.add(timer, forMode: .common)
                tickTimer = timer
            }
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    @objc private func animationTick() {
        advanceFrame()
    }

    @objc private func clockTick() {
        refresh()
    }

    private func advanceFrame() {
        let state = Self.iconState(
            isActive: coordinator.isActive,
            clamshellActive: coordinator.clamshellActive
        )

        // Never paint an active icon from here without checking. This method used to
        // assume "if the animation is running, the session is running", which is exactly
        // how the icon could be left stuck amber after a quick on/off.
        guard state != .off else {
            refresh()
            return
        }

        animationFrame = (animationFrame + 1) % EyeIcon.frameCount
        statusItem.button?.image = EyeIcon.image(
            style: effectiveStyle, state: state, frame: animationFrame
        )
    }

    @objc private func screensDidSleep() {
        // No point burning cycles animating an icon nobody can see.
        screensAsleep = true
        syncTimers()
    }

    @objc private func screensDidWake() {
        screensAsleep = false
        syncTimers()
    }

    // MARK: - NSMenuDelegate

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }
}
