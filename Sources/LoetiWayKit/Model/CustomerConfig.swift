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
    /// Agent name in Proton Pass. Default: `agent-<customer slug>`, like the customer's vault.
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

/// Contents of `.loeti-way.yaml` in a customer folder.
public struct CustomerConfig: Equatable, Sendable, Decodable {
    public static let fileName = ".loeti-way.yaml"

    public var customer: String
    public var proton: ProtonSettings
    /// Provider tokens, stored in `agent-<customer>` under the provider's title.
    public var tokens: TokenSection?
    /// Variable name → `pass://<vault>/<item>/<field>` in one of `proton.vaults`. `lw env` reads
    /// them with the customer's agent and exports the values.
    public var env: [String: String]?

    public init(customer: String, proton: ProtonSettings, tokens: TokenSection? = nil, env: [String: String]? = nil) {
        self.customer = customer
        self.proton = proton
        self.tokens = tokens
        self.env = env
    }

    enum CodingKeys: String, CodingKey {
        case customer, proton, tokens, env, github
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.github) {
            throw LWError("'github' heisst jetzt 'tokens.github'. Der Token liegt dann im Vault '\(VaultNaming.agentPrefix)<kunde>' als '\(TokenKind.github.itemTitle)', nicht mehr im Token-Vault")
        }
        customer = try container.decode(String.self, forKey: .customer)
        proton = try container.decode(ProtonSettings.self, forKey: .proton)
        tokens = try container.decodeIfPresent(TokenSection.self, forKey: .tokens)
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
    }

    public var agentName: String { proton.agent ?? VaultNaming.agentVault(customer: customer) }
    public var protonTokenItem: String { proton.tokenItem ?? "\(customer) Proton Agent" }
    /// Where the customer-wide provider tokens lie: `agent-<customer slug>`.
    public var vault: String { VaultNaming.agentVault(customer: customer) }
    public var grantedVaults: Set<String> { Set(proton.vaults.map(\.name)) }

    func resolvedTokens(directory: URL) -> (targets: [TokenTarget], problems: [String]) {
        tokens?.resolve(customer: customer, project: nil, vault: vault, directory: directory, parent: nil) ?? ([], [])
    }

    public func tokenTargets(directory: URL) -> [TokenTarget] {
        resolvedTokens(directory: directory).targets
    }

    /// What the customer exports everywhere below its folder, unless a project replaces it.
    public func exports(directory: URL) -> [Export] {
        Export.make(tokens: tokenTargets(directory: directory), env: env, project: nil)
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

    /// Checks what YAML decoding can't. `tokenVault` holds the tokens of all agents, so an
    /// agent must never get access to it; only `agent-` vaults may be granted (`VaultNaming`).
    public func validate(tokenVault: String) throws {
        var problems: [String] = []
        if customer.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("'customer' ist leer")
        }
        for name in [customer, protonTokenItem] where name.contains("/") {
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
                problems.append("Der Token-Vault '\(tokenVault)' darf nicht in 'proton.vaults' stehen: der Agent könnte sonst die Tokens aller Agents lesen")
            } else if let problem = VaultNaming.problem(agentVault: grant.name) {
                problems.append(problem)
            }
        }
        let directory = URL(fileURLWithPath: "/")
        let resolved = resolvedTokens(directory: directory)
        problems += resolved.problems
        if !resolved.targets.isEmpty && !grantedVaults.contains(vault) {
            problems.append("Die Tokens liegen in '\(vault)': diesen Vault in 'proton.vaults' freigeben")
        }
        problems += Export.problems(Export.make(tokens: resolved.targets, env: env, project: nil), granted: grantedVaults)
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

    public var tokenTargets: [TokenTarget] { config.tokenTargets(directory: directory) }

    /// Every variable `lw env` can set anywhere below this customer, sorted.
    public var variables: [String] {
        Set(config.exports(directory: directory).map(\.variable) + projects.flatMap { $0.exports.map(\.variable) }).sorted()
    }

    /// The project whose folder is `url` or contains it.
    public func project(containing url: URL) -> LoadedProject? {
        let path = url.standardizedFileURL.path
        return projects.first {
            let folder = $0.directory.standardizedFileURL.path
            return path == folder || path.hasPrefix(folder + "/")
        }
    }

    /// What `lw env` exports in `url`: the customer's values, replaced and extended by those of
    /// the project around it. Inside a broken project it throws: never fall back to the customer.
    public func exports(for url: URL) throws -> (project: LoadedProject?, exports: [Export]) {
        if let failure = projectFailure(containing: url) {
            throw LWError(failure.message)
        }
        var result = config.exports(directory: directory)
        let project = project(containing: url)
        if let project {
            let own = project.exports
            let kinds = Set(project.tokens.map(\.kind))
            let variables = Set(own.map(\.variable))
            result.removeAll { variables.contains($0.variable) || $0.token.map { kinds.contains($0.kind) } == true }
            result += own
        }
        return (project, result)
    }

    /// The token `lw token <kind>` works on: the named project's own, else the one that applies
    /// around `cwd` (project or customer), else the customer's. Pass `cwd` only when the
    /// customer was found from the working directory.
    public func tokenTarget(_ kind: TokenKind, project name: String?, cwd: URL?) throws -> TokenTarget {
        if let name {
            let project = try project(named: name)
            guard let target = project.tokens.first(where: { $0.kind == kind }) else {
                throw LWError("Projekt \(project.name) hat keinen eigenen \(kind.label)-Token ('tokens.\(kind.rawValue)' und 'vault: own' in \(project.file.path))")
            }
            return target
        }
        if let cwd {
            if let target = try exports(for: cwd).exports.compactMap(\.token).first(where: { $0.kind == kind }) {
                return target
            }
        } else if let target = tokenTargets.first(where: { $0.kind == kind }) {
            return target
        }
        let known = projects.filter { $0.tokens.contains { $0.kind == kind } }.map(\.name).joined(separator: ", ")
        throw LWError("\(config.customer) hat keinen \(kind.label)-Token ('tokens.\(kind.rawValue)' in \(CustomerConfig.fileName))"
            + (known.isEmpty ? "" : ". Projekte mit eigenem Token: \(known) (--project <name>)"))
    }

    /// The broken project config whose folder is `url` or contains it.
    public func projectFailure(containing url: URL) -> CustomerLocator.Failure? {
        let path = url.standardizedFileURL.path
        return projectFailures.first {
            let folder = $0.file.deletingLastPathComponent().standardizedFileURL.path
            return path == folder || path.hasPrefix(folder + "/")
        }
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
