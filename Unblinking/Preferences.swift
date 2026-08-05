import Foundation

enum BatteryPolicy: String, CaseIterable, Identifiable {
    case never
    case offWhenUnplugged
    case offBelowThreshold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never turn off automatically"
        case .offWhenUnplugged: return "Turn off when unplugged from power"
        case .offBelowThreshold: return "Turn off below a battery level"
        }
    }

    var explanation: String {
        switch self {
        case .never:
            return "Closed-lid mode stays on until you turn it off. On battery this can run "
                 + "the Mac down completely, in a closed bag it will also get hot."
        case .offWhenUnplugged:
            return "Closed-lid mode only holds while the charger is connected. Unplugging "
                 + "restores normal sleep immediately."
        case .offBelowThreshold:
            return "Closed-lid mode keeps working on battery, but restores normal sleep once "
                 + "the charge drops to your threshold."
        }
    }
}

enum TimeDisplay: String, CaseIterable, Identifiable {
    case elapsed
    case remaining

    var id: String { rawValue }
    var title: String { self == .elapsed ? "Elapsed" : "Remaining" }
}

/// How loud the menu bar icon should be.
///
/// A ladder rather than a set of unrelated looks: each step adds exactly one signal,
/// shape, then colour, then motion, so the choice is obvious without reading the
/// descriptions.
enum IconStyle: String, CaseIterable, Identifiable {
    /// Monochrome shape only. Blends in like any other menu bar icon.
    case subtle
    /// Colour, held still.
    case colour
    /// Colour plus a breathing glow.
    case vivid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtle: return "Subtle"
        case .colour: return "Colour"
        case .vivid: return "Vivid"
        }
    }

    var explanation: String {
        switch self {
        case .subtle:
            return "Monochrome, like every other menu bar icon. A shut eye when off, an "
                 + "open one when awake. Quietest, and the easiest to overlook."
        case .colour:
            return "Orange when awake, red when closed-lid mode is on. Obvious at a "
                 + "glance, with nothing moving."
        case .vivid:
            return "Colour plus a glow that breathes, faster and red when closed-lid mode "
                 + "is on. The hardest to walk past, which is rather the point."
        }
    }

    /// Only Vivid animates; the others are a single static frame.
    var isAnimated: Bool { self == .vivid }

    /// Reduce Motion is an accessibility setting, not a preference, it overrides the
    /// chosen style rather than being merged with it.
    static func effective(preferred: IconStyle, reduceMotion: Bool) -> IconStyle {
        (reduceMotion && preferred == .vivid) ? .colour : preferred
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let preventDisplaySleep = "preventDisplaySleep"
        static let preventIdleSleep = "preventIdleSleep"
        static let preventDiskSleep = "preventDiskSleep"
        static let preventSystemSleepOnAC = "preventSystemSleepOnAC"
        static let closedLidEnabled = "closedLidEnabled"
        static let batteryPolicy = "batteryPolicy"
        static let batteryThreshold = "batteryThreshold"
        static let iconStyle = "iconStyle"
        static let showTimeInMenuBar = "showTimeInMenuBar"
        static let timeDisplay = "timeDisplay"
        static let defaultDuration = "defaultDurationSeconds"
        static let restoreStateAtLaunch = "restoreStateAtLaunch"
        static let lastStateWasOn = "lastStateWasOn"
        static let weOwnSleepDisabled = "weOwnSleepDisabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.preventDisplaySleep: true,
            Key.preventIdleSleep: true,
            Key.preventDiskSleep: false,
            Key.preventSystemSleepOnAC: false,
            Key.closedLidEnabled: false,
            Key.batteryPolicy: BatteryPolicy.never.rawValue,
            Key.batteryThreshold: 20,
            Key.iconStyle: IconStyle.vivid.rawValue,
            Key.showTimeInMenuBar: false,
            Key.timeDisplay: TimeDisplay.elapsed.rawValue,
            Key.defaultDuration: 0,
            Key.restoreStateAtLaunch: false,
            Key.lastStateWasOn: false,
            Key.weOwnSleepDisabled: false,
        ])

        preventDisplaySleep = defaults.bool(forKey: Key.preventDisplaySleep)
        preventIdleSleep = defaults.bool(forKey: Key.preventIdleSleep)
        preventDiskSleep = defaults.bool(forKey: Key.preventDiskSleep)
        preventSystemSleepOnAC = defaults.bool(forKey: Key.preventSystemSleepOnAC)
        closedLidEnabled = defaults.bool(forKey: Key.closedLidEnabled)
        batteryPolicy = BatteryPolicy(rawValue: defaults.string(forKey: Key.batteryPolicy) ?? "") ?? .never
        batteryThreshold = defaults.integer(forKey: Key.batteryThreshold)
        iconStyle = IconStyle(rawValue: defaults.string(forKey: Key.iconStyle) ?? "") ?? .vivid
        showTimeInMenuBar = defaults.bool(forKey: Key.showTimeInMenuBar)
        timeDisplay = TimeDisplay(rawValue: defaults.string(forKey: Key.timeDisplay) ?? "") ?? .elapsed
        defaultDuration = SessionDuration(tagValue: defaults.integer(forKey: Key.defaultDuration))
        restoreStateAtLaunch = defaults.bool(forKey: Key.restoreStateAtLaunch)
        lastStateWasOn = defaults.bool(forKey: Key.lastStateWasOn)
        weOwnSleepDisabled = defaults.bool(forKey: Key.weOwnSleepDisabled)
    }

    // MARK: - Which assertions caffeinate should hold

    @Published var preventDisplaySleep: Bool {
        didSet { defaults.set(preventDisplaySleep, forKey: Key.preventDisplaySleep) }
    }
    @Published var preventIdleSleep: Bool {
        didSet { defaults.set(preventIdleSleep, forKey: Key.preventIdleSleep) }
    }
    @Published var preventDiskSleep: Bool {
        didSet { defaults.set(preventDiskSleep, forKey: Key.preventDiskSleep) }
    }
    @Published var preventSystemSleepOnAC: Bool {
        didSet { defaults.set(preventSystemSleepOnAC, forKey: Key.preventSystemSleepOnAC) }
    }

    // MARK: - Closed-lid mode

    @Published var closedLidEnabled: Bool {
        didSet { defaults.set(closedLidEnabled, forKey: Key.closedLidEnabled) }
    }
    @Published var batteryPolicy: BatteryPolicy {
        didSet { defaults.set(batteryPolicy.rawValue, forKey: Key.batteryPolicy) }
    }
    @Published var batteryThreshold: Int {
        didSet { defaults.set(batteryThreshold, forKey: Key.batteryThreshold) }
    }

    // MARK: - Appearance

    @Published var iconStyle: IconStyle {
        didSet { defaults.set(iconStyle.rawValue, forKey: Key.iconStyle) }
    }
    @Published var showTimeInMenuBar: Bool {
        didSet { defaults.set(showTimeInMenuBar, forKey: Key.showTimeInMenuBar) }
    }
    @Published var timeDisplay: TimeDisplay {
        didSet { defaults.set(timeDisplay.rawValue, forKey: Key.timeDisplay) }
    }

    // MARK: - Sessions

    @Published var defaultDuration: SessionDuration {
        didSet { defaults.set(defaultDuration.tagValue, forKey: Key.defaultDuration) }
    }
    @Published var restoreStateAtLaunch: Bool {
        didSet { defaults.set(restoreStateAtLaunch, forKey: Key.restoreStateAtLaunch) }
    }

    /// Whether the last run ended with the app switched on, only consulted when
    /// `restoreStateAtLaunch` is set.
    var lastStateWasOn: Bool {
        didSet { defaults.set(lastStateWasOn, forKey: Key.lastStateWasOn) }
    }

    /// Breadcrumb recording that *this app* is the one holding `SleepDisabled`.
    ///
    /// Written before the flag is set and cleared after it is unset, so a launch that
    /// finds the flag still set can tell "we crashed while owning it" (clear it silently)
    /// apart from "something else set this" (ask the user first).
    var weOwnSleepDisabled: Bool {
        didSet { defaults.set(weOwnSleepDisabled, forKey: Key.weOwnSleepDisabled) }
    }
}
