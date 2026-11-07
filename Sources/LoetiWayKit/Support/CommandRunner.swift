import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs one external tool. Tests replace it with a fake, so nothing in the kit starts a
/// process directly.
public protocol CommandRunner {
    /// Captures stdout and stderr. `stdin` and `environment` are the only ways to hand secrets
    /// to the tool: arguments are visible in the process list.
    func run(_ arguments: [String], stdin: Data?, environment: [String: String]) throws -> CommandResult

    /// Inherits the terminal, for output meant for the user and for interactive logins.
    func runAttached(_ arguments: [String], environment: [String: String]) throws -> Int32
}

/// Starts `executable` through `/usr/bin/env`, so it is looked up in `PATH`.
/// A missing executable ends with status 127.
///
/// The child gets lw's environment without any `PROTON_PASS_*` variable, plus `environment`:
/// which pass-cli login is used is always decided by lw, never by the calling shell.
public struct ProcessRunner: CommandRunner {
    public let executable: String

    public init(executable: String) {
        self.executable = executable
    }

    public func run(_ arguments: [String], stdin: Data?, environment: [String: String]) throws -> CommandResult {
        let process = makeProcess(arguments, environment: environment)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let inPipe {
            process.standardInput = inPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw LWError("\(executable) lässt sich nicht starten: \(error.localizedDescription)")
        }

        // Read both pipes while the child runs, otherwise a full pipe blocks it.
        let out = PipeReader(outPipe.fileHandleForReading)
        let err = PipeReader(errPipe.fileHandleForReading)
        if let inPipe, let stdin {
            let writer = inPipe.fileHandleForWriting
            // Throws instead of crashing if the child exits early (needs SIGPIPE ignored).
            try? writer.write(contentsOf: stdin)
            try? writer.close()
        }
        let outData = out.wait()
        let errData = err.wait()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: outData, stderr: errData)
    }

    public func runAttached(_ arguments: [String], environment: [String: String]) throws -> Int32 {
        let process = makeProcess(arguments, environment: environment)
        do {
            try process.run()
        } catch {
            throw LWError("\(executable) lässt sich nicht starten: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeProcess(_ arguments: [String], environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.environment = Self.childEnvironment(ProcessInfo.processInfo.environment, adding: environment)
        return process
    }

    static func childEnvironment(_ inherited: [String: String], adding extra: [String: String]) -> [String: String] {
        inherited.filter { !$0.key.hasPrefix("PROTON_PASS_") }.merging(extra) { _, new in new }
    }
}

/// Drains a pipe on a background queue.
private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
        DispatchQueue.global().async {
            self.data = self.handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}
