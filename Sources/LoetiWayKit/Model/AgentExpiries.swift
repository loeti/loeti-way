import Foundation
import Yams

/// `~/.config/loeti-way/agents.yaml`: when each agent's token expires, as last seen with the
/// account (`apply`, `renew`, `host`, `status --konto`). Lets `lw status` warn without logging
/// the account in; the agents' grants still need it.
public struct AgentExpiries: Equatable, Sendable {
    public var expires: [String: Date]
    public var checked: Date?

    public init(expires: [String: Date] = [:], checked: Date? = nil) {
        self.expires = expires
        self.checked = checked
    }

    private struct File: Codable {
        var checked: String?
        var agents: [String: String]
    }

    private static func formatter() -> ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

    public static func load(_ file: URL) -> AgentExpiries {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let decoded = try? YAMLDecoder().decode(File.self, from: text) else { return AgentExpiries() }
        let formatter = formatter()
        return AgentExpiries(
            expires: decoded.agents.compactMapValues { formatter.date(from: $0) },
            checked: decoded.checked.flatMap { formatter.date(from: $0) }
        )
    }

    public func save(_ file: URL) throws {
        let formatter = Self.formatter()
        let body = try YAMLEncoder().encode(File(
            checked: checked.map { formatter.string(from: $0) },
            agents: expires.mapValues { formatter.string(from: $0) }
        ))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("# Von lw geschrieben: Ablaufdaten der Agents, zuletzt mit deinem Konto gesehen.\n" + body)
            .write(to: file, atomically: true, encoding: .utf8)
    }

    /// Replaces everything with what the account sees now.
    public mutating func record(_ agents: [ProtonAgent], now: Date) {
        expires = Dictionary(agents.compactMap { agent in agent.expires.map { (agent.name, $0) } }) { first, _ in first }
        checked = now
    }
}
