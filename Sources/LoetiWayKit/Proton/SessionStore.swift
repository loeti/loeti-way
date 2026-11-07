import Foundation

/// The pass-cli logins lw keeps, each in its own `PROTON_PASS_SESSION_DIR` below `base`.
/// pass-cli's default session, which every process of the macOS user would find, stays empty.
///
/// - `host`: the host agent (viewer on the token vault only). Stays logged in, `lw env` uses it.
/// - `account`: the user's account, only while a command that needs it runs.
/// - `agent-<customer>`: a customer's agent, for the `env` values of `lw env`. Stays logged in.
public struct SessionStore {
    public static let host = "host"
    public static let account = "account"

    public let base: URL
    private let runner: any CommandRunner

    public init(base: URL, runner: any CommandRunner) {
        self.base = base
        self.runner = runner
    }

    public static func agent(customer: String) -> String {
        "agent-\(Slug.make(customer))"
    }

    public func directory(_ name: String) -> URL {
        base.appendingPathComponent(name, isDirectory: true)
    }

    /// pass-cli's own default session, the one every process finds. lw only looks at it.
    public func defaultSession() -> PassCLI {
        PassCLI(runner: runner)
    }

    public func pass(_ name: String, reason: String? = nil) -> PassCLI {
        PassCLI(runner: runner, sessionDirectory: directory(name), reason: reason)
    }

    /// An agent login, reused while pass-cli accepts it. `token` is only read for a new login.
    /// `expected` is the agent's name: a session of any other agent is refused, so a swapped
    /// token can't make lw read with someone else's rights.
    public func agent(_ name: String, expected: String, token: () throws -> String) throws -> PassCLI {
        let pass = pass(name)
        if case let .token(agent) = try pass.session() {
            try Self.check(agent, expected: expected)
            return pass
        }
        return try relogin(name, expected: expected, token: token())
    }

    /// Throws away the login in `name` and logs in again with `token`, e.g. after a renewal.
    public func relogin(_ name: String, expected: String, token: String) throws -> PassCLI {
        try reset(name)
        let pass = pass(name)
        try pass.login(token: token)
        guard case let .token(agent) = try pass.session() else {
            throw LWError("Nach dem Anmelden mit dem Agent-Token meldet pass-cli keine Agent-Sitzung.")
        }
        do {
            try Self.check(agent, expected: expected)
        } catch {
            try? reset(name)
            throw error
        }
        return pass
    }

    /// Fails closed: a session that doesn't name its agent is refused too.
    static func check(_ agent: String?, expected: String) throws {
        guard let agent else {
            throw LWError("pass-cli info nennt den angemeldeten Agent nicht, erwartet '\(expected)'; nichts gelesen.")
        }
        guard agent == expected else {
            throw LWError("Angemeldet ist Agent '\(agent)', erwartet '\(expected)'. Der Token gehört zu einem anderen Agent; nichts gelesen.")
        }
    }

    /// Logs out (as far as possible) and deletes the directory.
    public func reset(_ name: String) throws {
        let directory = directory(name)
        if FileManager.default.fileExists(atPath: directory.path) {
            try? pass(name).logout(force: true)
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Logs the user's account in through the browser, runs `body`, then logs out and deletes
    /// the session, also when `body` fails.
    public func withAccount<T>(_ body: (PassCLI) async throws -> T) async throws -> T {
        try reset(Self.account)
        let pass = pass(Self.account)
        defer { endAccount() }
        try pass.loginInteractively()
        try pass.session().requireAccount()
        return try await body(pass)
    }

    func endAccount() {
        let pass = pass(Self.account)
        if (try? pass.logout()) == nil {
            try? pass.logout(force: true)
        }
        try? FileManager.default.removeItem(at: directory(Self.account))
    }
}

/// `host-token`: the host agent's token in a file only the user may read.
public enum HostToken {
    public static func read(_ file: URL) throws -> String {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch {
            throw LWError("\(file.path) fehlt. Host-Agent einrichten: lw host --setup, oder einen vorhandenen Token ablegen: lw host --set-token")
        }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard mode & 0o077 == 0 else {
            throw LWError("\(file.path) ist für andere lesbar (\(String(mode, radix: 8))). Beheben: chmod 600 \(file.path)")
        }
        let token = PassCLI.stripPrefix(try String(contentsOf: file, encoding: .utf8))
        guard !token.isEmpty else { throw LWError("\(file.path) ist leer") }
        return token
    }

    /// Writes with mode 0600 from the start and replaces the file atomically.
    public static func write(_ token: String, to file: URL) throws {
        let token = PassCLI.stripPrefix(token)
        guard token.hasPrefix("pst_") else {
            throw LWError("Das ist kein Proton-Agent-Token (beginnt nicht mit pst_).")
        }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
        // open() with 0600, so the token is never readable by others, not even briefly.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw LWError("\(temporary.path) lässt sich nicht anlegen") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data((token + "\n").utf8))
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw LWError("\(temporary.path) lässt sich nicht schreiben")
        }
        guard rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw LWError("\(file.path) lässt sich nicht ersetzen")
        }
    }
}
