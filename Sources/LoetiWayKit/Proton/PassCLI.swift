import Foundation

public struct ProtonAgent: Equatable, Sendable {
    public var id: String
    public var name: String
    public var expires: Date?

    public init(id: String, name: String, expires: Date?) {
        self.id = id
        self.name = name
        self.expires = expires
    }
}

/// One entry of `pass-cli pat access list-access`.
public struct AccessGrant: Equatable, Sendable {
    public enum Target: String, Sendable { case vault, item, folder }

    public var target: Target
    public var shareID: String
    /// Vault name, item title or folder name.
    public var name: String
    /// Lowercased: `viewer`, `editor`, `manager`, `owner` or `custom`.
    public var role: String

    public init(target: Target, shareID: String, name: String, role: String) {
        self.target = target
        self.shareID = shareID
        self.name = name
        self.role = role
    }
}

public struct VaultItem: Equatable, Sendable {
    public var id: String
    public var shareID: String
    public var title: String
    public var isActive: Bool

    public init(id: String, shareID: String, title: String, isActive: Bool = true) {
        self.id = id
        self.shareID = shareID
        self.title = title
        self.isActive = isActive
    }
}

/// Typed wrapper around the `pass-cli` commands lw needs. Secrets only travel over stdin,
/// stdout or the environment, never as arguments. JSON shapes follow pass-cli's source.
///
/// Each instance belongs to one login: `sessionDirectory` becomes `PROTON_PASS_SESSION_DIR`,
/// see `SessionStore`. Agents must give a `reason` for reading items.
public struct PassCLI {
    public static let tokenPrefix = "PROTON_PASS_PERSONAL_ACCESS_TOKEN="
    static let tokenVariable = "PROTON_PASS_PERSONAL_ACCESS_TOKEN"
    static let sessionVariable = "PROTON_PASS_SESSION_DIR"
    static let reasonVariable = "PROTON_PASS_AGENT_REASON"

    private let runner: any CommandRunner
    public let sessionDirectory: URL?
    public let reason: String?

    public init(runner: any CommandRunner, sessionDirectory: URL? = nil, reason: String? = nil) {
        self.runner = runner
        self.sessionDirectory = sessionDirectory
        self.reason = reason
    }

    /// The same login with another reason for the audit log.
    public func with(reason: String) -> PassCLI {
        PassCLI(runner: runner, sessionDirectory: sessionDirectory, reason: reason)
    }

    var environment: [String: String] {
        var environment: [String: String] = [:]
        environment[Self.sessionVariable] = sessionDirectory?.path
        environment[Self.reasonVariable] = reason
        return environment
    }

    // MARK: Session

    /// Who pass-cli is logged in as, from `pass-cli info`.
    public func session() throws -> PassSession {
        let result = try runner.run(["info"], stdin: nil, environment: environment)
        if result.status == 127 { throw Self.notFound }
        guard result.status == 0 else { return .loggedOut }
        return PassSession.parse(info: result.stdoutString)
    }

    /// Logs in with an agent token. The token goes through the environment; `--pat` would show
    /// it in the process list.
    public func login(token: String) throws {
        let token = Self.stripPrefix(token)
        let result = try runner.run(["login"], stdin: nil, environment: environment.merging([Self.tokenVariable: token]) { _, new in new })
        if result.status == 127 { throw Self.notFound }
        guard result.status == 0 else {
            let detail = Self.redacted(result.stderrString, token: token)
            throw LWError("Anmelden mit dem Agent-Token ist fehlgeschlagen" + (detail.isEmpty ? "" : " (pass-cli: \(detail))") + ". Ist er abgelaufen oder erneuert worden?")
        }
    }

    /// pass-cli's message without any line that could carry a token.
    static func redacted(_ message: String, token: String) -> String {
        let secretParts = token.components(separatedBy: "::").filter { $0.count >= 8 }
        return message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                line.contains("pst_") || secretParts.contains(where: line.contains) || line.contains(tokenPrefix) ? "[geschwärzt]" : line
            }
            .joined(separator: " / ")
    }

    /// The web login of the user's account, in the browser.
    public func loginInteractively() throws {
        let status = try runner.runAttached(["login"], environment: environment)
        if status == 127 { throw Self.notFound }
        guard status == 0 else { throw LWError("Anmelden bei Proton Pass ist fehlgeschlagen.") }
    }

    public func logout(force: Bool = false) throws {
        try call(["logout"] + (force ? ["--force"] : []))
    }

    // MARK: Agents

    public func listAgents() throws -> [ProtonAgent] {
        struct DTO: Decodable {
            let patID: String
            let name: String
            let expireTime: Int64?
            enum CodingKeys: String, CodingKey {
                case patID = "pat_id", name, expireTime = "expire_time"
            }
        }
        let dtos = try decode([DTO].self, from: call(["agent", "list", "--output", "json"]).stdout, what: "agent list")
        return dtos.map {
            ProtonAgent(id: $0.patID, name: $0.name, expires: $0.expireTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }

    public func listAccess(agentID: String) throws -> [AccessGrant] {
        let result = try call(["pat", "access", "list-access", "--personal-access-token-id", agentID, "--output", "json"])
        let dtos = try decode([AccessDTO].self, from: result.stdout, what: "pat access list-access")
        return dtos.compactMap { dto in
            guard let target = AccessGrant.Target(rawValue: dto.type.lowercased()) else { return nil }
            let name = dto.vaultName ?? dto.itemTitle ?? dto.folderName ?? "?"
            return AccessGrant(target: target, shareID: dto.shareID, name: name, role: dto.role.name)
        }
    }

    /// Creates the agent without grants and returns its token (without the `NAME=` prefix).
    /// Grants follow separately because `--vault` here always means viewer.
    public func createAgent(name: String, lifetime: TokenLifetime) throws -> String {
        let result = try call(["agent", "create", name, "--expiration", lifetime.rawValue])
        return try Self.extractToken(result.stdout)
    }

    /// The old token stops working immediately; grants are kept.
    public func renewAgent(name: String, lifetime: TokenLifetime) throws -> String {
        let result = try call(["agent", "renew", name, "--expiration", lifetime.rawValue, "--output", "json"])
        return try Self.extractToken(result.stdout)
    }

    public func grant(agent: String, vault: String, role: VaultRole) throws {
        try call(["agent", "access", "grant", agent, "--vault-name", vault, "--role", role.rawValue])
    }

    public func revoke(agent: String, shareID: String) throws {
        try call(["agent", "access", "revoke", agent, "--share-id", shareID])
    }

    public func monitor(agent: String, limit: Int) throws -> Int32 {
        try runner.runAttached(["agent", "monitor", agent, "--limit", String(limit)], environment: environment)
    }

    // MARK: Items

    public func listItems(vault: String) throws -> [VaultItem] {
        struct List: Decodable { let items: [ItemDTO] }
        let result = try call(["item", "list", "--vault-name", vault, "--output", "json"])
        return try decode(List.self, from: result.stdout, what: "item list").items.map {
            VaultItem(id: $0.id, shareID: $0.shareID, title: $0.title, isActive: $0.state.map { $0.lowercased() != "trashed" } ?? true)
        }
    }

    /// Passes the note over stdin as a template, so the value never shows up in `ps`.
    public func createNote(vault: String, title: String, note: String) throws {
        let template: [String: Any] = ["title": title, "note": note, "extra_fields": [Any]()]
        let data = try JSONSerialization.data(withJSONObject: template)
        try call(["item", "create", "note", "--vault-name", vault, "--from-template", "-"], stdin: data)
    }

    public func deleteItem(shareID: String, itemID: String) throws {
        try call(["item", "delete", "--share-id", shareID, "--item-id", itemID])
    }

    public func readNote(vault: String, title: String) throws -> String {
        try read(Self.reference(vault: vault, item: title))
    }

    /// One field, addressed as `pass://<vault>/<item>/<field>`.
    public func read(_ reference: String) throws -> String {
        let result = try call(["item", "view", reference])
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LWError("'\(reference)' ist leer") }
        return value
    }

    public static func reference(vault: String, item: String, field: String = "note") -> String {
        "pass://\(vault)/\(item)/\(field)"
    }

    // MARK: Helpers

    static let notFound = LWError("pass-cli nicht gefunden. Installieren (https://protonpass.github.io/pass-cli/) oder LW_PASS_CLI setzen.")

    @discardableResult
    func call(_ arguments: [String], stdin: Data? = nil) throws -> CommandResult {
        let result = try runner.run(arguments, stdin: stdin, environment: environment)
        if result.status == 127 { throw Self.notFound }
        guard result.status == 0 else {
            let command = arguments.prefix { !$0.hasPrefix("-") }.joined(separator: " ")
            let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LWError("pass-cli \(command) ist fehlgeschlagen" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return result
    }

    static func extractToken(_ json: Data) throws -> String {
        struct Output: Decodable { let token: String }
        let token = stripPrefix(try decode(Output.self, from: json, what: "Token-Ausgabe").token)
        guard !token.isEmpty else { throw LWError("pass-cli hat einen leeren Token geliefert") }
        return token
    }

    public static func stripPrefix(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(tokenPrefix) ? String(trimmed.dropFirst(tokenPrefix.count)) : trimmed
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        try Self.decode(type, from: data, what: what)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Never echo the payload: for token output it contains the secret.
            throw LWError("Unerwartete Ausgabe von pass-cli (\(what)): \(error.localizedDescription)")
        }
    }
}

/// `PersonalAccessTokenAccess`: internally tagged with `type`, snake_case fields.
private struct AccessDTO: Decodable {
    let type: String
    let shareID: String
    let role: RoleValue
    let vaultName: String?
    let itemTitle: String?
    let folderName: String?

    enum CodingKeys: String, CodingKey {
        case type, role
        case shareID = "share_id"
        case vaultName = "vault_name"
        case itemTitle = "item_title"
        case folderName = "folder_name"
    }
}

/// `ShareRole` serializes as `"Viewer"` or, for custom roles, as `{"Custom": {...}}`.
private struct RoleValue: Decodable {
    let name: String

    init(from decoder: Decoder) throws {
        if let plain = try? decoder.singleValueContainer().decode(String.self) {
            name = plain.lowercased()
            return
        }
        let container = try decoder.container(keyedBy: AnyKey.self)
        name = (container.allKeys.first?.stringValue ?? "custom").lowercased()
    }
}

private struct ItemDTO: Decodable {
    let id: String
    let shareID: String
    let title: String
    let state: String?

    enum CodingKeys: String, CodingKey {
        case id, title, state
        case shareID = "share_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        shareID = try container.decode(String.self, forKey: .shareID)
        title = try container.decode(String.self, forKey: .title)
        state = try? container.decode(String.self, forKey: .state)
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
