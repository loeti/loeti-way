import Foundation
@testable import LoetiWayKit

/// Stands in for pass-cli: answers by argument prefix (last match wins) and records calls.
final class FakeRunner: CommandRunner {
    struct Call: Equatable {
        let arguments: [String]
        let stdin: Data?
        var environment: [String: String] = [:]

        var sessionDirectory: String? { environment["PROTON_PASS_SESSION_DIR"] }
    }

    private var responses: [(prefix: [String], result: CommandResult)] = []
    /// Answered first and used up, in order: for state changes such as a login.
    private var onceResponses: [(prefix: [String], result: CommandResult)] = []
    private(set) var calls: [Call] = []
    var attachedStatus: Int32 = 0

    func on(_ prefix: [String], status: Int32 = 0, stdout: String = "", stderr: String = "") {
        responses.append((prefix, CommandResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))))
    }

    func once(_ prefix: [String], status: Int32 = 0, stdout: String = "", stderr: String = "") {
        onceResponses.append((prefix, CommandResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))))
    }

    /// Like `on`, but only for calls in the session directory named `session` (its last component).
    func onSession(_ session: String, _ prefix: [String], status: Int32 = 0, stdout: String = "", stderr: String = "") {
        sessionResponses.append((session, prefix, CommandResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))))
    }

    func onceSession(_ session: String, _ prefix: [String], status: Int32 = 0, stdout: String = "", stderr: String = "") {
        onceSessionResponses.append((session, prefix, CommandResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))))
    }

    private var sessionResponses: [(session: String, prefix: [String], result: CommandResult)] = []
    private var onceSessionResponses: [(session: String, prefix: [String], result: CommandResult)] = []

    func run(_ arguments: [String], stdin: Data?, environment: [String: String]) throws -> CommandResult {
        let call = Call(arguments: arguments, stdin: stdin, environment: environment)
        calls.append(call)
        let session = call.sessionDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
        if let index = onceSessionResponses.firstIndex(where: { $0.session == session && arguments.starts(with: $0.prefix) }) {
            return onceSessionResponses.remove(at: index).result
        }
        if let index = onceResponses.firstIndex(where: { arguments.starts(with: $0.prefix) }) {
            return onceResponses.remove(at: index).result
        }
        if let match = sessionResponses.last(where: { $0.session == session && arguments.starts(with: $0.prefix) }) {
            return match.result
        }
        return responses.last { arguments.starts(with: $0.prefix) }?.result ?? CommandResult(status: 0)
    }

    func runAttached(_ arguments: [String], environment: [String: String]) throws -> Int32 {
        calls.append(Call(arguments: arguments, stdin: nil, environment: environment))
        return attachedStatus
    }

    /// Calls that change something in Proton Pass, as joined argument strings.
    var mutations: [String] {
        let readOnly: Set<String> = ["info", "list", "list-access", "view"]
        return calls.map(\.arguments).filter { arguments in
            !arguments.contains { readOnly.contains($0) }
        }.map { $0.joined(separator: " ") }
    }
}

struct FakeChecker: GitHubTokenChecker {
    var result: Result<GitHubTokenInfo, LWError>
    /// token → repositories it covers.
    var access: [String: Set<String>] = [:]

    func check(token: String) async throws -> GitHubTokenInfo {
        try result.get()
    }

    func canAccess(token: String, repository: GitHubRepository) async throws -> Bool {
        access[token]?.contains(repository.description) ?? false
    }
}

enum Fixtures {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lw-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static let kundeA = """
    customer: KundeA
    proton:
      expiration: 1m
      vaults:
        - name: agent-kundea
        - name: agent-kundea-infra
          role: editor
    github:
      owner: kundea-org
      repositories: [web, api]
    """
}
