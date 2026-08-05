import Foundation

/// Owns the `/usr/bin/caffeinate` child process — the layer that blocks idle, display
/// and disk sleep. It does **not** affect lid-close sleep; see `ClamshellController`.
@MainActor
final class CaffeineProcess {
    struct Options: Equatable {
        var display: Bool
        var idle: Bool
        var disk: Bool
        var systemOnAC: Bool
    }

    /// Pure, so the argument list can be asserted in tests.
    ///
    /// `-w` is the orphan guard: caffeinate drops its assertions and exits the moment the
    /// watched pid dies, so even a `kill -9` of this app cannot leave one running.
    nonisolated static func arguments(
        options: Options,
        duration: SessionDuration,
        watchPID: pid_t
    ) -> [String] {
        var args: [String] = []
        if options.display { args.append("-d") }
        if options.idle { args.append("-i") }
        if options.disk { args.append("-m") }
        if options.systemOnAC { args.append("-s") }

        // Turning every assertion off would make caffeinate a no-op that still looks
        // "on" in the menu bar. Idle sleep is the meaningful floor.
        if args.isEmpty { args.append("-i") }

        if let seconds = duration.secondsValue, seconds > 0 {
            args.append(contentsOf: ["-t", String(seconds)])
        }
        args.append(contentsOf: ["-w", String(watchPID)])
        return args
    }

    private var process: Process?

    /// Called when caffeinate exits on its own — `-t` elapsed, or something killed it.
    var onUnexpectedExit: (() -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }
    var childPID: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    func start(options: Options, duration: SessionDuration) throws {
        stop()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = Self.arguments(
            options: options,
            duration: duration,
            watchPID: ProcessInfo.processInfo.processIdentifier
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.handleTermination(of: finished) }
        }

        try process.run()
        self.process = process
    }

    func stop() {
        guard let process, process.isRunning else {
            self.process = nil
            return
        }

        process.terminate()

        // Give it a moment to go down politely, then insist. caffeinate has nothing to
        // flush, so this never takes meaningful time in practice.
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        // Cleared synchronously: stop() does not return until the child is gone, so any
        // termination handler that lands afterwards belongs to a run we've finished with.
        self.process = nil
    }

    private func handleTermination(of finished: Process) {
        // Termination handlers are delivered asynchronously, so by the time one arrives
        // its run may already have been stopped, or replaced by a newer one. Only the
        // process we're currently tracking is allowed to end a session — otherwise a
        // quick off/on could have the old child's handler wipe out the new child.
        guard finished === process else { return }

        process = nil
        onUnexpectedExit?()
    }
}
