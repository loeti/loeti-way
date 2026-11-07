import Foundation

/// The token providers lw knows. Each one fixes the title of the secure note, so a token can be
/// stored by hand as well: in `agent-<customer>` (customer-wide) or `agent-<customer>-<project>`
/// (one project), titled `itemTitle`, the token as the note's content.
///
/// A new provider adds a case here, its settings to `ProviderSettings` and `TokenSection`, and
/// optionally a creation helper (`lw token <provider>`) and checks for `lw status`.
public enum TokenKind: String, CaseIterable, Sendable, Codable {
    case github

    public var label: String {
        switch self {
        case .github: "GitHub"
        }
    }

    public var itemTitle: String {
        switch self {
        case .github: "GitHub Token"
        }
    }

    /// Name inside the container; on the host it is `LW_ENV_<name>`.
    public var defaultVariable: String {
        switch self {
        case .github: "GH_TOKEN"
        }
    }
}

/// `tokens:` in a customer or project file, as written. Every key is optional; a project
/// inherits what it leaves out from the customer.
public struct TokenSection: Decodable, Equatable, Sendable {
    public var github: GitHubPartial?

    public init(github: GitHubPartial? = nil) {
        self.github = github
    }

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        for key in container.allKeys where TokenKind(rawValue: key.stringValue) == nil {
            let known = TokenKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw LWError("Unbekannter Anbieter 'tokens.\(key.stringValue)'. Bekannt: \(known)")
        }
        github = try container.decodeIfPresent(GitHubPartial.self, forKey: Key(stringValue: TokenKind.github.rawValue))
    }

    public var isEmpty: Bool { github == nil }

    /// Resolved tokens stored in `vault`. `parent` is the customer's section when resolving a project.
    func resolve(customer: String, project: String?, vault: String, directory: URL, parent: TokenSection?) -> (targets: [TokenTarget], problems: [String]) {
        var targets: [TokenTarget] = []
        var problems: [String] = []
        if let github {
            let inherited = parent?.github
            let section = "tokens.github"
            if let owner = github.owner ?? inherited?.owner {
                let settings = GitHubSettings(
                    owner: owner,
                    expiresInDays: github.expiresInDays ?? inherited?.expiresInDays ?? 90,
                    permissions: github.permissions ?? inherited?.permissions ?? GitHubSettings.defaultPermissions,
                    repositories: github.repositories ?? project.map { [$0] } ?? [],
                    tokenName: github.tokenName ?? ([customer] + (project.map { [$0] } ?? []) + ["PAT"]).joined(separator: "_")
                )
                problems += settings.problems(section: section)
                targets.append(TokenTarget(
                    customer: customer, project: project, vault: vault,
                    variable: github.variable ?? inherited?.variable ?? TokenKind.github.defaultVariable,
                    settings: .github(settings), directory: directory
                ))
            } else {
                problems.append("'\(section).owner' fehlt" + (project == nil ? "" : ", und \(customer) hat auch keinen"))
            }
        }
        return (targets, problems)
    }
}

/// `tokens.github` as written.
public struct GitHubPartial: Decodable, Equatable, Sendable {
    public var owner: String?
    public var expiresInDays: Int?
    public var permissions: [String: String]?
    public var repositories: [String]?
    public var tokenName: String?
    public var variable: String?

    public init(owner: String? = nil, expiresInDays: Int? = nil, permissions: [String: String]? = nil,
                repositories: [String]? = nil, tokenName: String? = nil, variable: String? = nil) {
        self.owner = owner
        self.expiresInDays = expiresInDays
        self.permissions = permissions
        self.repositories = repositories
        self.tokenName = tokenName
        self.variable = variable
    }

    enum CodingKeys: String, CodingKey {
        case owner, permissions, repositories, variable
        case expiresInDays = "expires_in_days"
        case tokenName = "token_name"
        case tokenItem = "token_item"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.tokenItem) {
            throw LWError("'tokens.github.token_item' gibt es nicht mehr: der Token liegt immer als '\(TokenKind.github.itemTitle)' im Vault des Kunden bzw. Projekts")
        }
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        expiresInDays = try container.decodeIfPresent(Int.self, forKey: .expiresInDays)
        permissions = try container.decodeIfPresent([String: String].self, forKey: .permissions)
        repositories = try container.decodeIfPresent([String].self, forKey: .repositories)
        tokenName = try container.decodeIfPresent(String.self, forKey: .tokenName)
        variable = try container.decodeIfPresent(String.self, forKey: .variable)
    }
}

/// A resolved GitHub fine-grained PAT.
public struct GitHubSettings: Equatable, Sendable {
    /// Resource owner of the fine-grained PAT: an organisation or a user.
    public var owner: String
    public var expiresInDays: Int
    /// GitHub permission name → `read` | `write` | `admin`, e.g. `contents: write`.
    public var permissions: [String: String]
    /// Only shown as a reminder: GitHub's form can't preselect repositories.
    public var repositories: [String]
    /// Name of the token on GitHub: `<customer>_PAT` or `<customer>_<project>_PAT` by default.
    public var tokenName: String

    public static let defaultPermissions = ["contents": "write", "pull_requests": "write"]

    public init(owner: String, expiresInDays: Int = 90, permissions: [String: String] = defaultPermissions,
                repositories: [String] = [], tokenName: String) {
        self.owner = owner
        self.expiresInDays = expiresInDays
        self.permissions = permissions
        self.repositories = repositories
        self.tokenName = tokenName
    }

    func problems(section: String) -> [String] {
        var problems: [String] = []
        if owner.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("'\(section).owner' ist leer")
        }
        if !(1...366).contains(expiresInDays) {
            problems.append("'\(section).expires_in_days' muss zwischen 1 und 366 liegen")
        }
        for (name, level) in permissions.sorted(by: { $0.key < $1.key }) where !["read", "write", "admin"].contains(level) {
            problems.append("'\(section).permissions.\(name)': '\(level)' ist nicht read, write oder admin")
        }
        return problems
    }
}

public enum ProviderSettings: Equatable, Sendable {
    case github(GitHubSettings)

    public var kind: TokenKind {
        switch self {
        case .github: .github
        }
    }
}

/// One provider token of a customer or a project: where it lies and how it is exported.
public struct TokenTarget: Equatable, Sendable {
    public var customer: String
    /// nil for the customer-wide token.
    public var project: String?
    /// `agent-<customer>` or `agent-<customer>-<project>`.
    public var vault: String
    /// Name inside the container.
    public var variable: String
    public var settings: ProviderSettings
    /// Folder of the customer or project.
    public var directory: URL

    public init(customer: String, project: String?, vault: String, variable: String, settings: ProviderSettings, directory: URL) {
        self.customer = customer
        self.project = project
        self.vault = vault
        self.variable = variable
        self.settings = settings
        self.directory = directory
    }

    public var kind: TokenKind { settings.kind }
    public var itemTitle: String { kind.itemTitle }
    public var reference: String { PassCLI.reference(vault: vault, item: itemTitle) }

    public var github: GitHubSettings? {
        switch settings {
        case let .github(settings): settings
        }
    }

    /// `loeti` or `loeti / loeti-way`.
    public var label: String {
        project.map { "\(customer) / \($0)" } ?? customer
    }

    /// The command that creates or renews this token.
    public var command: String {
        "lw token \(kind.rawValue) \(Self.shellWord(customer))" + (project.map { " --project \(Self.shellWord($0))" } ?? "")
    }

    static func shellWord(_ text: String) -> String {
        let plain = text.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        return plain && !text.isEmpty ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One variable `lw env` exports for a folder.
public struct Export: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case token(TokenTarget)
        case env
    }

    /// Name inside the container; on the host `LW_ENV_<variable>`.
    public var variable: String
    /// `pass://<vault>/<item>/<field>`.
    public var reference: String
    public var source: Source
    /// The project that defines it, nil for the customer.
    public var project: String?

    public init(variable: String, reference: String, source: Source, project: String?) {
        self.variable = variable
        self.reference = reference
        self.source = source
        self.project = project
    }

    public var token: TokenTarget? {
        if case let .token(target) = source { return target }
        return nil
    }

    public var hostVariable: String { EnvNaming.hostVariable(variable) }

    /// Tokens first, then `env`, each sorted by variable.
    static func make(tokens: [TokenTarget], env: [String: String]?, project: String?) -> [Export] {
        tokens.sorted { $0.variable < $1.variable }.map { Export(variable: $0.variable, reference: $0.reference, source: .token($0), project: project) }
            + (env ?? [:]).sorted { $0.key < $1.key }.map { Export(variable: $0.key, reference: $0.value, source: .env, project: project) }
    }

    /// Problems with the variables and references of one file. `granted` are the vaults the
    /// customer's agent may read.
    static func problems(_ exports: [Export], granted: Set<String>) -> [String] {
        var problems: [String] = []
        var seen = Set<String>()
        for export in exports {
            let path = export.token.map { "tokens.\($0.kind.rawValue).variable" } ?? "env.\(export.variable)"
            if !seen.insert(export.variable).inserted {
                problems.append("'\(export.variable)' wird mehrfach gesetzt (tokens und env)")
            }
            if let problem = EnvNaming.problem(variable: export.variable) {
                problems.append("'\(path)': \(problem)")
            }
            guard case .env = export.source else { continue }
            switch PassReference(export.reference) {
            case nil:
                problems.append("'\(path)': '\(export.reference)' ist keine Referenz der Form pass://<vault>/<eintrag>/<feld>")
            case let parsed? where !VaultNaming.isAgentVault(parsed.vault) || !granted.contains(parsed.vault):
                problems.append("'\(path)': Vault '\(parsed.vault)' steht nicht in 'proton.vaults'; der Agent könnte ihn nicht lesen")
            default:
                break
            }
        }
        return problems
    }
}
