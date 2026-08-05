import Foundation

struct StrayProcess: Identifiable, Hashable {
    let pid: pid_t
    let command: String

    var id: pid_t { pid }
}

/// Finds `caffeinate` processes running outside this app.
///
/// These are reported, never killed automatically, plenty of tools spawn `caffeinate`
/// legitimately (the `claude` CLI runs `caffeinate -i -t 300`, for one), and silently
/// killing someone else's assertion would break their work.
enum StrayProcessWatcher {
    /// Pure, so the `ps` output format can be pinned in tests.
    static func parse(psOutput: String) -> [StrayProcess] {
        psOutput.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: " ") else { return nil }
            guard let pid = pid_t(trimmed[trimmed.startIndex..<separator]) else { return nil }

            let command = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }

            return StrayProcess(pid: pid, command: command)
        }
    }

    static func find(excluding ownChildPID: pid_t?) -> [StrayProcess] {
        let uid = String(getuid())
        let pgrep = Shell.run("/usr/bin/pgrep", ["-x", "-U", uid, "caffeinate"])

        // pgrep exits 1 when nothing matched, an empty list, not an error.
        let pids = pgrep.stdout
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != ownChildPID }

        guard !pids.isEmpty else { return [] }

        let listed = pids.map(String.init).joined(separator: ",")
        let ps = Shell.run("/bin/ps", ["-o", "pid=,command=", "-p", listed])
        return parse(psOutput: ps.stdout)
    }

    /// Sends SIGTERM. These are the user's own processes, so no privileges are needed.
    static func stop(_ process: StrayProcess) {
        kill(process.pid, SIGTERM)
    }
}
