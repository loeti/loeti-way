import Foundation
import Yams

/// Values accepted by `pass-cli agent create|renew --expiration`.
public enum TokenLifetime: String, Codable, CaseIterable, Sendable {
    case oneHour = "1h"
    case oneDay = "1d"
    case oneWeek = "1w"
    case oneMonth = "1m"
    case threeMonths = "3m"
    case sixMonths = "6m"
    case oneYear = "1y"

    public static func parse(_ raw: String) throws -> TokenLifetime {
        guard let value = TokenLifetime(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
            let allowed = allCases.map(\.rawValue).joined(separator: ", ")
            throw LWError("Unbekannte Laufzeit '\(raw)'. Erlaubt: \(allowed)")
        }
        return value
    }
}

/// Roles `pass-cli agent access grant --role` accepts.
public enum VaultRole: String, Codable, CaseIterable, Sendable {
    case viewer, editor, manager
}

public struct VaultGrant: Equatable, Sendable, Codable {
    public var name: String
    public var role: VaultRole

    public init(name: String, role: VaultRole = .viewer) {
        self.name = name
        self.role = role
    }

    enum CodingKeys: String, CodingKey { case name, role }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let raw = try container.decodeIfPresent(String.self, forKey: .role) ?? VaultRole.viewer.rawValue
        guard let role = VaultRole(rawValue: raw.lowercased()) else {
            throw LWError("Unbekannte Rolle '\(raw)' für Vault '\(name)'. Erlaubt: viewer, editor, manager")
        }
        self.role = role
    }
}

public struct ProtonSettings: Equatable, Sendable, Codable {
    /// Agent name in Proton Pass. Default: `asylum-<customer slug>`.
    public var agent: String?
    public var expiration: TokenLifetime
    /// Title of the note in the token vault. Default: `<customer> Proton Agent`.
    public var tokenItem: String?
    public var vaults: [VaultGrant]

    public init(agent: String? = nil, expiration: TokenLifetime = .threeMonths, tokenItem: String? = nil, vaults: [VaultGrant]) {
        self.agent = agent
        self.expiration = expiration
        self.tokenItem = tokenItem
        self.vaults = vaults
    }

    enum CodingKeys: String, CodingKey {
        case agent, expiration, vaults
        case tokenItem = "token_item"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        expiration = try TokenLifetime.parse(try container.decodeIfPresent(String.self, forKey: .expiration) ?? "3m")
        tokenItem = try container.decodeIfPresent(String.self, forKey: .tokenItem)
        vaults = try container.decodeIfPresent([VaultGrant].self, forKey: .vaults) ?? []
    }
}

public struct GitHubSettings: Equatable, Sendable, Codable {
    /// Resource owner of the fine-grained PAT: an organisation or a user.
    public var owner: String
    public var expiresInDays: Int
    /// GitHub permission name → `read` | `write` | `admin`, e.g. `contents: write`.
    public var permissions: [String: String]
    /// Only shown as a reminder: GitHub's form can't preselect repositories.
    public var repositories: [String]
    /// Title of the note in the token vault. Default: `<customer> GitHub PAT`.
    public var tokenItem: String?
    /// Name of the token on GitHub. Default: `<customer> Asylum`.
    public var tokenName: String?

    public static let defaultPermissions = ["contents": "write", "pull_requests": "write"]

    public init(owner: String, expiresInDays: Int = 90, permissions: [String: String] = [:], repositories: [String] = [], tokenItem: String? = nil, tokenName: String? = nil) {
        self.owner = owner
        self.expiresInDays = expiresInDays
        self.permissions = permissions
        self.repositories = repositories
        self.tokenItem = tokenItem
        self.tokenName = tokenName
    }

    enum CodingKeys: String, CodingKey {
        case owner, permissions, repositories
        case expiresInDays = "expires_in_days"
        case tokenItem = "token_item"
        case tokenName = "token_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decode(String.self, forKey: .owner)
        expiresInDays = try container.decodeIfPresent(Int.self, forKey: .expiresInDays) ?? 90
        permissions = try container.decodeIfPresent([String: String].self, forKey: .permissions)
            ?? Self.defaultPermissions
        repositories = try container.decodeIfPresent([String].self, forKey: .repositories) ?? []
        tokenItem = try container.decodeIfPresent(String.self, forKey: .tokenItem)
        tokenName = try container.decodeIfPresent(String.self, forKey: .tokenName)
    }

    /// Problems with the values; `section` is the YAML path for messages, e.g. `github`.
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

/// Contents of `.loeti-way.yaml` in a customer folder.
public struct CustomerConfig: Equatable, Sendable, Codable {
    public static let fileName = ".loeti-way.yaml"

    public var customer: String
    public var proton: ProtonSettings
    public var github: GitHubSettings?

    public init(customer: String, proton: ProtonSettings, github: GitHubSettings? = nil) {
        self.customer = customer
        self.proton = proton
        self.github = github
    }

    public var agentName: String { proton.agent ?? "asylum-\(Slug.make(customer))" }
    public var protonTokenItem: String { proton.tokenItem ?? "\(customer) Proton Agent" }
    public var githubTokenItem: String { github?.tokenItem ?? "\(customer) GitHub PAT" }
    public var githubTokenName: String { github?.tokenName ?? "\(customer) Asylum" }

    /// The customer-wide GitHub PAT, nil without a `github` section.
    public func githubTarget(directory: URL) -> GitHubTarget? {
        github.map {
            GitHubTarget(customer: customer, project: nil, settings: $0, tokenItem: githubTokenItem, tokenName: githubTokenName, directory: directory)
        }
    }

    public static func parse(_ yaml: String) throws -> CustomerConfig {
        do {
            return try YAMLDecoder().decode(CustomerConfig.self, from: yaml)
        } catch let error as LWError {
            throw error
        } catch let DecodingError.keyNotFound(key, context) {
            let path = (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
            throw LWError("Pflichtfeld '\(path)' fehlt")
        } catch let DecodingError.typeMismatch(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw LWError("Falscher Typ bei '\(path)': \(context.debugDescription)")
        } catch {
            throw LWError("Ungültiges YAML: \(error)")
        }
    }

    /// Checks what YAML decoding can't. `tokenVault` holds the tokens of all customers, so an
    /// agent must never get access to it; only `agent-` vaults may be granted (`VaultNaming`).
    public func validate(tokenVault: String) throws {
        var problems: [String] = []
        if customer.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("'customer' ist leer")
        }
        for name in [customer, protonTokenItem, githubTokenItem] where name.contains("/") {
            problems.append("'\(name)' enthält '/', das geht nicht in pass://-Referenzen")
        }
        if proton.vaults.isEmpty {
            problems.append("'proton.vaults' ist leer")
        }
        var seen = Set<String>()
        for grant in proton.vaults where !seen.insert(grant.name).inserted {
            problems.append("Vault '\(grant.name)' steht mehrfach in 'proton.vaults'")
        }
        for grant in proton.vaults {
            if grant.name == tokenVault {
                problems.append("Der Token-Vault '\(tokenVault)' darf nicht in 'proton.vaults' stehen: der Agent könnte sonst die Tokens aller Kunden lesen")
            } else if let problem = VaultNaming.problem(agentVault: grant.name) {
                problems.append(problem)
            }
        }
        if let github {
            problems += github.problems(section: "github")
        }
        if !problems.isEmpty {
            throw LWError(problems.joined(separator: "\n"))
        }
    }
}

/// A parsed config together with where it was found, and the projects below it.
public struct LoadedCustomer: Sendable, Equatable {
    public let config: CustomerConfig
    public let file: URL
    public var projects: [LoadedProject]
    /// Project configs below this customer that couldn't be loaded.
    public var projectFailures: [CustomerLocator.Failure]

    public init(config: CustomerConfig, file: URL, projects: [LoadedProject] = [], projectFailures: [CustomerLocator.Failure] = []) {
        self.config = config
        self.file = file
        self.projects = projects
        self.projectFailures = projectFailures
    }

    public var directory: URL { file.deletingLastPathComponent() }

    /// Every GitHub PAT of this customer: the customer-wide one first, then the projects'.
    public var githubTargets: [GitHubTarget] {
        (config.githubTarget(directory: directory).map { [$0] } ?? []) + projects.map(\.github)
    }

    /// Titles of every note this customer reads or writes in the token vault.
    public var tokenItems: Set<String> {
        Set([config.protonTokenItem] + githubTargets.map(\.tokenItem))
    }

    /// The project whose folder is `url` or contains it.
    public func project(containing url: URL) -> LoadedProject? {
        let path = url.standardizedFileURL.path
        return projects.first {
            let folder = $0.directory.standardizedFileURL.path
            return path == folder || path.hasPrefix(folder + "/")
        }
    }

    /// The PAT `lw github` works on: the named project, else the project around `cwd`, else the
    /// customer-wide one. Pass `cwd` only when the customer was found from the working directory.
    public func githubTarget(project name: String?, cwd: URL?) throws -> GitHubTarget {
        if let name {
            return try project(named: name).github
        }
        if let cwd {
            if let project = project(containing: cwd) { return project.github }
            let path = cwd.standardizedFileURL.path
            if let failure = projectFailures.first(where: {
                let folder = $0.file.deletingLastPathComponent().standardizedFileURL.path
                return path == folder || path.hasPrefix(folder + "/")
            }) {
                // Never fall back to the customer's wider token inside a broken project.
                throw LWError(failure.message)
            }
        }
        if let target = config.githubTarget(directory: directory) { return target }
        let known = projects.map(\.name).joined(separator: ", ")
        throw LWError("\(config.customer) hat keinen github-Abschnitt in \(CustomerConfig.fileName)"
            + (known.isEmpty ? "" : ". Projekt-PATs: \(known) (--project <name>)"))
    }

    /// `name` matches the project name or its folder name, case-insensitively.
    public func project(named name: String) throws -> LoadedProject {
        let matches = projects.filter {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
                || $0.directory.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }
        if matches.count == 1 { return matches[0] }
        if let failure = projectFailures.first(where: {
            $0.file.deletingLastPathComponent().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }) {
            throw LWError(failure.message)
        }
        let known = projects.map(\.name).joined(separator: ", ")
        throw LWError("Kein Projekt '\(name)' bei \(config.customer)" + (known.isEmpty ? " (es gibt noch keine, `lw init --project`)" : ". Vorhanden: \(known)"))
    }
}
