import Foundation

enum PrivilegeError: LocalizedError, Equatable {
    /// No silent path to root yet — the one-time authorization hasn't been installed.
    case notAuthorized
    case invalidUserName(String)
    case validationFailed(String)
    case userCancelled
    case installFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Unblinking isn't allowed to change the system sleep setting yet."
        case .invalidUserName(let name):
            return "The user name \"\(name)\" contains characters that can't be written "
                 + "into a sudoers rule safely."
        case .validationFailed(let detail):
            return "The generated permission rule failed validation, so nothing was "
                 + "installed.\n\n\(detail)"
        case .userCancelled:
            return "Authorization was cancelled."
        case .installFailed(let detail):
            return "Couldn't install the permission rule.\n\n\(detail)"
        case .commandFailed(let detail):
            return "Couldn't change the system sleep setting.\n\n\(detail)"
        }
    }
}

/// Whatever can run `pmset -a disablesleep` as root.
///
/// Kept behind a protocol because with a Developer ID account the same job can be done by
/// an `SMAppService` root daemon, which would swap in here without touching call sites.
protocol PrivilegedRunner: Sendable {
    var isAuthorizationInstalled: Bool { get }
    func setSleepDisabled(_ disabled: Bool) throws
    func installAuthorization() throws
    func removeAuthorization() throws
}

/// Grants silent root access to exactly two commands via a `sudoers.d` drop-in.
struct SudoersRunner: PrivilegedRunner {
    /// Must contain no "." and must not end in "~".
    ///
    /// sudo skips such names inside an @includedir directory, to avoid picking up package
    /// manager and editor temp files. A reverse-DNS name like "com.amrhamdy.unblinking"
    /// installs perfectly and is then silently ignored — the file is there, correctly
    /// owned, and does nothing. `ruleFileNameIsLoadable` pins this down.
    static let ruleFileName = "unblinking"
    static let ruleFilePath = "/etc/sudoers.d/\(ruleFileName)"

    /// Names this rule has shipped under before. Removed on both install and uninstall, so
    /// a rename never strands a working grant in /etc that nothing will ever clean up.
    ///
    /// `com.amrhamdy.caffeinate` was the first attempt, which sudo silently ignored because
    /// of the dots. `caffeinate-app` worked, but predates the rename to Unblinking.
    static let legacyRuleFilePaths = [
        "/etc/sudoers.d/com.amrhamdy.caffeinate",
        "/etc/sudoers.d/caffeinate-app",
    ]

    /// True when the file name will actually be read by sudo.
    static func ruleFileNameIsLoadable(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(".") && !name.hasSuffix("~")
    }

    /// Pure, so tests can hand the generated text straight to `visudo -c`.
    ///
    /// Deliberately lists both exact command lines rather than using a wildcard: this
    /// grants the ability to toggle lid-close sleep and nothing else. `pmset`'s other
    /// subcommands still require a password.
    static func ruleText(user: String) -> String {
        """
        # Installed by Unblinking.app.
        #
        # Lets \(user) toggle lid-close sleep without a password prompt every time.
        # Scoped to these two exact commands — no wildcards, no other pmset subcommands.
        #
        # Remove with:  sudo rm \(ruleFilePath)
        # (or use "Remove Permission" in Unblinking's Closed-Lid settings)
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
        """
    }

    static func isValidUserName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-")
        }
    }

    /// Escapes a shell command for embedding in an AppleScript string literal.
    static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - PrivilegedRunner

    var isAuthorizationInstalled: Bool {
        // Require the grant to live under the *current* file name, not just to work. A
        // rule left over from an earlier name still grants the same commands, so without
        // this check a renamed app would keep running on the old file forever and never
        // migrate — leaving a stale grant in /etc named after an app that no longer
        // exists. Failing here costs one prompt and cleans that up for good.
        guard FileManager.default.fileExists(atPath: Self.ruleFilePath) else { return false }

        // `sudo -n -l <command>` looks like the natural probe but is useless here:
        // *listing* privileges is itself subject to authentication, so it reports
        // "a password is required" even when the command asked about is NOPASSWD.
        //
        // Instead, write back the value the system already holds. That is a genuine
        // exercise of the grant, changes nothing, and succeeds only if the rule is live.
        let current = SleepDisabledFlag.read() ? "1" : "0"
        return Shell.run("/usr/bin/sudo", [
            "-n", "/usr/bin/pmset", "-a", "disablesleep", current,
        ]).succeeded
    }

    func setSleepDisabled(_ disabled: Bool) throws {
        let result = Shell.run("/usr/bin/sudo", [
            "-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0",
        ])
        guard result.succeeded else {
            // sudo exits non-zero both when the rule is missing and when it would need a
            // password. Either way the caller's move is to run the install flow.
            if result.stderr.contains("password is required")
                || result.stderr.contains("not allowed")
                || result.stderr.contains("may not run") {
                throw PrivilegeError.notAuthorized
            }
            throw PrivilegeError.commandFailed(result.combinedOutput)
        }
    }

    func installAuthorization() throws {
        let user = NSUserName()
        guard Self.isValidUserName(user) else {
            throw PrivilegeError.invalidUserName(user)
        }
        guard Self.ruleFileNameIsLoadable(Self.ruleFileName) else {
            throw PrivilegeError.installFailed(
                "\"\(Self.ruleFileName)\" contains a '.' or ends in '~', so sudo would "
                    + "install it and then ignore it."
            )
        }

        // The per-user temp directory is mode 0700, so no other user can swap this file
        // out between validation and install.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("unblinking-sudoers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try Self.ruleText(user: user).write(to: staging, atomically: true, encoding: .utf8)
        } catch {
            throw PrivilegeError.installFailed(error.localizedDescription)
        }

        // Validate BEFORE anything goes near /etc. A malformed sudoers file can lock the
        // user out of sudo entirely, so this check is not optional.
        let validation = Shell.run("/usr/sbin/visudo", ["-c", "-f", staging.path])
        guard validation.succeeded else {
            throw PrivilegeError.validationFailed(validation.combinedOutput)
        }

        // 0440 root:wheel — sudo silently ignores drop-ins with looser permissions.
        // The same elevated call clears any inert file from the old dotted name, so the
        // user isn't asked for a password twice.
        let command = "/usr/bin/install -m 0440 -o root -g wheel "
            + "'\(staging.path)' '\(Self.ruleFilePath)' && "
            + "/bin/rm -f \(Self.legacyRuleFilePaths.map { "'\($0)'" }.joined(separator: " "))"
        try runWithAdministratorPrivileges(command)

        guard isAuthorizationInstalled else {
            throw PrivilegeError.installFailed(
                "The rule was written to \(Self.ruleFilePath) but sudo still won't run "
                    + "pmset without a password.\n\nCheck that @includedir "
                    + "/private/etc/sudoers.d appears after the %admin line in "
                    + "/etc/sudoers — sudoers uses the last matching rule."
            )
        }
    }

    func removeAuthorization() throws {
        try runWithAdministratorPrivileges(
            "/bin/rm -f " + ([Self.ruleFilePath] + Self.legacyRuleFilePaths)
                .map { "'\($0)'" }
                .joined(separator: " ")
        )
    }

    // MARK: - Private

    private enum ScriptOutcome {
        case success
        case cancelled
        /// Couldn't run at all — nothing was shown to the user, so it is safe to retry
        /// another way without risking a second password dialog.
        case unavailable(String)
    }

    /// Runs a command as root via the standard macOS authentication dialog.
    ///
    /// Tried in-process first, because the dialog names whichever process asked for
    /// authorization: in-process it reads "Unblinking wants to make changes", via a
    /// subprocess it reads "osascript wants to make changes". An unexplained osascript
    /// prompt is exactly the kind of thing people cancel.
    ///
    /// The subprocess remains as a fallback because Hardened Runtime can refuse to load
    /// scripting additions into the app itself, and a working prompt beats a pretty one.
    private func runWithAdministratorPrivileges(_ command: String) throws {
        let script = "do shell script \"\(Self.escapeForAppleScript(command))\" "
            + "with administrator privileges"

        switch runInProcess(script) {
        case .success:
            return
        case .cancelled:
            throw PrivilegeError.userCancelled
        case .unavailable:
            break
        }

        let result = Shell.run("/usr/bin/osascript", ["-e", script])
        guard result.succeeded else {
            let output = result.combinedOutput
            if output.contains("User canceled") || output.contains("-128") {
                throw PrivilegeError.userCancelled
            }
            throw PrivilegeError.installFailed(output)
        }
    }

    private func runInProcess(_ script: String) -> ScriptOutcome {
        guard let applescript = NSAppleScript(source: script) else {
            return .unavailable("the script could not be compiled")
        }

        var errorInfo: NSDictionary?
        applescript.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .success }

        // Raw key strings rather than the imported constants, whose Swift spelling has
        // moved between SDKs.
        let code = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? 0
        if code == -128 { return .cancelled }

        let message = errorInfo["NSAppleScriptErrorMessage"] as? String
        return .unavailable(message ?? "AppleScript error \(code)")
    }
}
