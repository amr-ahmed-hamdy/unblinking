import Foundation
import IOKit
import IOKit.ps

/// Read-only view of lid and power state. Everything here works without privileges.
enum PowerEnvironment {
    /// Reads a boolean property from `IOPMrootDomain`.
    private static func rootDomainFlag(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }

        return property.takeRetainedValue() as? Bool
    }

    /// `true` when the lid is shut. Nil on hardware without a lid.
    static var isLidClosed: Bool? { rootDomainFlag("AppleClamshellState") }

    /// Whether closing the lid would put this Mac to sleep right now.
    ///
    /// Derived from `SleepDisabled`, which is the flag that actually decides this.
    ///
    /// Note for anyone tempted to use `IOPMrootDomain`'s `AppleClamshellCausesSleep`
    /// instead: it is not a forecast. Measured on macOS 26 with the lid open, it reads
    /// "No" whether `SleepDisabled` is 0 or 1 — it describes the *current* clamshell
    /// state, not what a future lid close would do. `ClamshellPredictionTests` pins this.
    static var lidCloseWouldSleep: Bool { !SleepDisabledFlag.read() }

    static var isOnACPower: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        return type == kIOPMACPowerKey
    }

    /// Current charge as a percentage, or nil on a machine with no battery.
    static var batteryPercentage: Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int,
               maximum > 0 {
                return Int((Double(current) / Double(maximum) * 100).rounded())
            }
        }
        return nil
    }
}

/// Fires a callback whenever the power source changes — charger plugged or unplugged,
/// battery level moved. Cheaper and more responsive than polling.
final class PowerSourceObserver {
    private var source: CFRunLoopSource?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { rawContext in
            guard let rawContext else { return }
            let observer = Unmanaged<PowerSourceObserver>
                .fromOpaque(rawContext)
                .takeUnretainedValue()
            observer.handler()
        }

        guard let runLoopSource = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else { return }

        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}
