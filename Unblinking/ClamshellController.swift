import Foundation

/// Owns the system-wide `SleepDisabled` flag, the only software switch that stops a
/// MacBook sleeping when the lid closes.
///
/// Power assertions (what `caffeinate` creates) cannot do this. Closing the lid triggers
/// *clamshell sleep*, a lower-level suspend that assertions never see.
///
/// The flag is global and survives reboots, so every path that sets it must have a
/// matching path that clears it, including the ones that only run at next launch.
/// The system-wide `SleepDisabled` flag, read straight from `pmset`.
///
/// Split out from `ClamshellController` so the privilege layer can read the current value
/// without depending on a main-actor type.
enum SleepDisabledFlag {
    /// Pulls `SleepDisabled` out of `pmset -g live`, which prints it under
    /// "System-wide power settings" as `SleepDisabled\t\t0`.
    static func parse(from output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SleepDisabled") else { continue }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            return fields[1] == "1"
        }
        return nil
    }

    /// Reads the live value from the system rather than trusting cached state.
    static func read() -> Bool {
        parse(from: Shell.run("/usr/bin/pmset", ["-g", "live"]).stdout) ?? false
    }
}

@MainActor
final class ClamshellController {
    private let runner: PrivilegedRunner

    init(runner: PrivilegedRunner = SudoersRunner()) {
        self.runner = runner
    }

    var isSleepDisabled: Bool { SleepDisabledFlag.read() }

    var isAuthorized: Bool { runner.isAuthorizationInstalled }

    func setEnabled(_ enabled: Bool) throws {
        try runner.setSleepDisabled(enabled)
    }

    /// Blocking, shows the administrator password dialog. Call from a detached task.
    nonisolated func installAuthorization() throws {
        try SudoersRunner().installAuthorization()
    }

    nonisolated func removeAuthorization() throws {
        try SudoersRunner().removeAuthorization()
    }
}
