import Foundation

/// Runs short-lived command line tools and captures their output.
///
/// Every call site passes an absolute path, never a bare name resolved through `PATH`,
/// because this app shells out to tools that matter (`pmset`, `sudo`, `visudo`) and a
/// hijacked `PATH` must not be able to redirect them.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { status == 0 }
        var combinedOutput: String {
            [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    /// Mutable storage the pipe-draining closures can share without tripping over
    /// captured-var rules.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String] = []) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        // Drain both pipes concurrently. Waiting on the process first would deadlock
        // as soon as either pipe buffer fills.
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.amrhamdy.unblinking.shell", attributes: .concurrent)

        group.enter()
        queue.async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }

    /// Off-main-thread variant, for anything that can block for a long time,
    /// most importantly the administrator password prompt.
    static func runAsync(_ launchPath: String, _ arguments: [String] = []) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(launchPath, arguments))
            }
        }
    }
}
