import Foundation

/// Result of running an external executable.
public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// stderr if there is any, otherwise stdout. Handy for surfacing failures.
    public var combinedDiagnostic: String? {
        let err = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}

/// Runs external binaries.
///
/// There is deliberately no shell anywhere in this type: the executable is always
/// an absolute path that the caller verified, and arguments are passed as a real
/// argument vector. A volume label containing `;`, a space, `$(...)` or a newline
/// is therefore just a string in `argv`, never something a shell could interpret.
public enum ProcessRunner {
    public enum RunError: Error {
        case executableMissing(String)
        case notExecutable(String)
        case launchFailed(String)
    }

    public static func run(_ executablePath: String,
                           arguments: [String],
                           timeout: TimeInterval = 30,
                           environment: [String: String]? = nil) throws -> CommandResult {
        guard executablePath.hasPrefix("/") else {
            throw RunError.executableMissing(executablePath)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executablePath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw RunError.executableMissing(executablePath)
        }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw RunError.notExecutable(executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently so a chatty child cannot deadlock on a full
        // pipe buffer while we are blocked waiting for it to exit.
        let collector = OutputCollector()
        let group = DispatchGroup()
        for (handle, isStdout) in [(outPipe.fileHandleForReading, true),
                                   (errPipe.fileHandleForReading, false)] {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let data = handle.readDataToEndOfFile()
                collector.append(data, isStdout: isStdout)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                // Give it a moment to die politely before giving up on it entirely.
                let hardDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < hardDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)

        return CommandResult(exitCode: process.terminationStatus,
                             standardOutput: collector.stdoutString,
                             standardError: collector.stderrString,
                             timedOut: timedOut)
    }
}

/// Thread-safe accumulator for the two pipe readers.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout { out.append(data) } else { err.append(data) }
    }

    var stdoutString: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var stderrString: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }
}
