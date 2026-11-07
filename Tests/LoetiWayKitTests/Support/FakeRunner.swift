import Foundation
@testable import LoetiWayKit

/// Stands in for pass-cli: answers by argument prefix (last match wins) and records calls.
final class FakeRunner: CommandRunner {
    struct Call: Equatable {
        let arguments: [String]
        let stdin: Data?
    }

    private var responses: [(prefix: [String], result: CommandResult)] = []
    private(set) var calls: [Call] = []

    func on(_ prefix: [String], status: Int32 = 0, stdout: String = "", stderr: String = "") {
        responses.append((prefix, CommandResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))))
    }

    func run(_ arguments: [String], stdin: Data?) throws -> CommandResult {
        calls.append(Call(arguments: arguments, stdin: stdin))
        return responses.last { arguments.starts(with: $0.prefix) }?.result ?? CommandResult(status: 0)
    }

    func runAttached(_ arguments: [String]) throws -> Int32 {
        calls.append(Call(arguments: arguments, stdin: nil))
        return 0
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

    func check(token: String) async throws -> GitHubTokenInfo {
        try result.get()
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
        - name: KundeA
        - name: KundeA Infra
          role: editor
    github:
      owner: kundea-org
      repositories: [web, api]
    """
}
