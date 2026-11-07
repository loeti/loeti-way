import Foundation
import Yams

/// One GitHub PAT that lw manages: the customer-wide one or a project's.
public struct GitHubTarget: Equatable, Sendable {
    public var customer: String
    /// nil for the customer-wide PAT.
    public var project: String?
    public var settings: GitHubSettings
    /// Title of the note in the token vault.
    public var tokenItem: String
    /// Name of the token on GitHub.
    public var tokenName: String
    /// Folder whose `.envrc` exports this token.
    public var directory: URL

    public init(customer: String, project: String?, settings: GitHubSettings, tokenItem: String, tokenName: String, directory: URL) {
        self.customer = customer
        self.project = project
        self.settings = settings
        self.tokenItem = tokenItem
        self.tokenName = tokenName
        self.directory = directory
    }

    /// `loeti` or `loeti / loeti-way`.
    public var label: String {
        project.map { "\(customer) / \($0)" } ?? customer
    }
}

/// `.loeti-way-project.yaml` in a project folder below a customer: a GitHub PAT of its own
/// that replaces the customer's in this folder. The Proton agent stays the customer's.
///
/// Every `github` key is optional; missing ones come from the customer's `github` section.
public enum ProjectConfig {
    public static let fileName = ".loeti-way-project.yaml"

    private struct File: Decodable {
        var project: String?
        var github: Partial?

        struct Partial: Decodable {
            var owner: String?
            var expiresInDays: Int?
            var permissions: [String: String]?
            var repositories: [String]?
            var tokenItem: String?
            var tokenName: String?

            enum CodingKeys: String, CodingKey {
                case owner, permissions, repositories
                case expiresInDays = "expires_in_days"
                case tokenItem = "token_item"
                case tokenName = "token_name"
            }
        }
    }

    /// Parses a project file and fills the gaps from `customer`. `folder` names the project
    /// unless the file sets `project`.
    public static func resolve(_ yaml: String, folder: URL, customer: CustomerConfig) throws -> LoadedProject {
        let file: File
        do {
            file = try YAMLDecoder().decode(File.self, from: yaml)
        } catch let DecodingError.typeMismatch(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw LWError("Falscher Typ bei '\(path)': \(context.debugDescription)")
        } catch {
            throw LWError("Ungültiges YAML: \(error)")
        }

        let name = file.project ?? folder.lastPathComponent
        let partial = file.github ?? File.Partial()
        let inherited = customer.github
        guard let owner = partial.owner ?? inherited?.owner else {
            throw LWError("'github.owner' fehlt, und \(customer.customer) hat auch keinen github-Abschnitt")
        }
        let settings = GitHubSettings(
            owner: owner,
            expiresInDays: partial.expiresInDays ?? inherited?.expiresInDays ?? 90,
            permissions: partial.permissions ?? inherited?.permissions ?? GitHubSettings.defaultPermissions,
            repositories: partial.repositories ?? [name],
            tokenItem: partial.tokenItem,
            tokenName: partial.tokenName
        )
        let target = GitHubTarget(
            customer: customer.customer,
            project: name,
            settings: settings,
            tokenItem: partial.tokenItem ?? "\(customer.customer) \(name) GitHub PAT",
            tokenName: partial.tokenName ?? "\(customer.customer) \(name) Asylum",
            directory: folder
        )

        var problems = settings.problems(section: "github")
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("'project' ist leer")
        }
        if target.tokenItem.contains("/") {
            problems.append("'\(target.tokenItem)' enthält '/', das geht nicht in pass://-Referenzen")
        }
        if !problems.isEmpty {
            throw LWError(problems.joined(separator: "\n"))
        }
        return LoadedProject(name: name, github: target)
    }
}

public struct LoadedProject: Equatable, Sendable {
    public var name: String
    public var github: GitHubTarget

    public init(name: String, github: GitHubTarget) {
        self.name = name
        self.github = github
    }

    public var directory: URL { github.directory }
    public var file: URL { directory.appendingPathComponent(ProjectConfig.fileName) }
}
