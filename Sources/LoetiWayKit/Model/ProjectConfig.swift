import Foundation
import Yams

/// `.loeti-way-project.yaml` in a project folder below a customer. Without own values the
/// project gets what the customer exports. The Proton agent is always the customer's.
///
/// ```yaml
/// vault: own          # agent-<customer>-<folder>, granted in the customer's proton.vaults
/// tokens:
///   github: {repositories: [web]}   # replaces the customer's GitHub token in this folder
/// env:
///   X: pass://agent-kunde-web/Item/field
/// ```
///
/// The file lies where agents can write. The project is named after its folder, its vault is
/// derived from customer and folder, and `lw env` only uses what `lw apply` registered.
public enum ProjectConfig {
    public static let fileName = ".loeti-way-project.yaml"
    /// The only value `vault` takes.
    public static let ownVault = "own"

    private struct File: Decodable {
        var project: String?
        var vault: String?
        var tokens: TokenSection?
        var env: [String: String]?

        enum CodingKeys: String, CodingKey {
            case project, vault, tokens, env, github
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.github) {
                throw LWError("'github' heisst jetzt 'tokens.github' und braucht 'vault: own': der Token liegt im Vault des Projekts als '\(TokenKind.github.itemTitle)'")
            }
            project = try container.decodeIfPresent(String.self, forKey: .project)
            vault = try container.decodeIfPresent(String.self, forKey: .vault)
            tokens = try container.decodeIfPresent(TokenSection.self, forKey: .tokens)
            env = try container.decodeIfPresent([String: String].self, forKey: .env)
        }
    }

    /// Parses a project file against `customer`. `folder` names the project.
    public static func resolve(_ yaml: String, folder: URL, customer: CustomerConfig) throws -> LoadedProject {
        let file: File
        do {
            file = try YAMLDecoder().decode(File.self, from: yaml)
        } catch let error as LWError {
            throw error
        } catch let DecodingError.typeMismatch(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw LWError("Falscher Typ bei '\(path)': \(context.debugDescription)")
        } catch {
            throw LWError("Ungültiges YAML: \(error)")
        }

        let name = folder.lastPathComponent
        var problems: [String] = []
        if let project = file.project, project != name {
            problems.append("'project: \(project)' passt nicht zum Ordner '\(name)'. Der Projektname ist immer der Ordnername; 'project' weglassen")
        }

        var vault: String?
        switch file.vault {
        case nil:
            break
        case ownVault?:
            if Slug.make(name).isEmpty {
                problems.append("Aus dem Ordnernamen '\(name)' entsteht kein Vault-Name; Ordner umbenennen")
            } else {
                let derived = VaultNaming.projectVault(customer: customer.customer, project: name)
                vault = derived
                if !customer.grantedVaults.contains(derived) {
                    problems.append("'vault: own' ist '\(derived)'; diesen Vault in 'proton.vaults' von \(customer.customer) (\(CustomerConfig.fileName)) freigeben")
                }
            }
        case let other?:
            problems.append("'vault: \(other)': erlaubt ist nur 'vault: own' (\(VaultNaming.projectVault(customer: customer.customer, project: name)))")
        }

        var tokens: [TokenTarget] = []
        if let section = file.tokens, !section.isEmpty {
            if let vault {
                let resolved = section.resolve(customer: customer.customer, project: name, vault: vault, directory: folder, parent: customer.tokens)
                tokens = resolved.targets
                problems += resolved.problems
            } else if file.vault == nil {
                problems.append("Eigene Tokens brauchen 'vault: own': sie liegen im Vault des Projekts (\(VaultNaming.projectVault(customer: customer.customer, project: name)))")
            }
        }
        problems += Export.problems(Export.make(tokens: tokens, env: file.env, project: name), granted: customer.grantedVaults)
        if !problems.isEmpty {
            throw LWError(problems.joined(separator: "\n"))
        }
        return LoadedProject(name: name, directory: folder, vault: vault, tokens: tokens, env: file.env ?? [:])
    }
}

public struct LoadedProject: Equatable, Sendable {
    public var name: String
    public var directory: URL
    /// `agent-<customer>-<folder>` with `vault: own`.
    public var vault: String?
    /// Own tokens; they replace the customer's of the same provider in this folder.
    public var tokens: [TokenTarget]
    public var env: [String: String]

    public init(name: String, directory: URL, vault: String? = nil, tokens: [TokenTarget] = [], env: [String: String] = [:]) {
        self.name = name
        self.directory = directory
        self.vault = vault
        self.tokens = tokens
        self.env = env
    }

    public var file: URL { directory.appendingPathComponent(ProjectConfig.fileName) }

    /// Only the project's own values.
    public var exports: [Export] { Export.make(tokens: tokens, env: env, project: name) }
}
