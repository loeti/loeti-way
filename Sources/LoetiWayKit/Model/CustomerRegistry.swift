import Foundation
import Yams

/// `~/.config/loeti-way/customers.yaml`: the customers the user has confirmed with `lw apply`.
///
/// A `.loeti-way.yaml` can lie in a folder an agent can write (a repo mounted into Asylum), and
/// it names the notes the host agent reads. So `lw env` and every command except `apply` only
/// accept a customer config that sits in a registered folder and names exactly the registered
/// agent and notes. The registry lives outside every project, where no container writes.
public struct CustomerRegistry: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var directory: String
        public var customer: String
        public var agent: String
        public var protonTokenItem: String
        public var githubTokenItem: String?
        /// `name:role` per granted vault.
        public var vaults: [String]
        /// Variable name → reference, as in `env:`.
        public var env: [String: String]

        public init(directory: String, customer: String, agent: String, protonTokenItem: String, githubTokenItem: String?,
                    vaults: [String] = [], env: [String: String] = [:]) {
            self.directory = directory
            self.customer = customer
            self.agent = agent
            self.protonTokenItem = protonTokenItem
            self.githubTokenItem = githubTokenItem
            self.vaults = vaults
            self.env = env
        }

        public init(_ loaded: LoadedCustomer) {
            self.init(
                directory: loaded.directory.standardizedFileURL.path,
                customer: loaded.config.customer,
                agent: loaded.config.agentName,
                protonTokenItem: loaded.config.protonTokenItem,
                githubTokenItem: loaded.config.github == nil ? nil : loaded.config.githubTokenItem,
                vaults: loaded.config.proton.vaults.map { "\($0.name):\($0.role.rawValue)" }.sorted(),
                env: loaded.config.env ?? [:]
            )
        }

        enum CodingKeys: String, CodingKey {
            case directory, customer, agent, vaults, env
            case protonTokenItem = "proton_token_item"
            case githubTokenItem = "github_token_item"
        }

        var items: [String] { [protonTokenItem] + (githubTokenItem.map { [$0] } ?? []) }
    }

    private struct File: Codable {
        var customers: [Entry]
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public static func load(_ file: URL) throws -> CustomerRegistry {
        guard FileManager.default.fileExists(atPath: file.path) else { return CustomerRegistry() }
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            return CustomerRegistry(entries: try YAMLDecoder().decode(File.self, from: text).customers)
        } catch {
            throw LWError("\(file.path): \(error)")
        }
    }

    public func save(_ file: URL) throws {
        let body = try YAMLEncoder().encode(File(customers: entries.sorted { $0.directory < $1.directory }))
        let text = "# Von lw apply verwaltet. Nur diese Kunden bekommen Tokens über lw env.\n" + body
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    public func entry(directory: URL) -> Entry? {
        let path = directory.standardizedFileURL.path
        return entries.first { $0.directory == path }
    }

    /// Throws unless `loaded` is registered in its folder with the same agent and notes.
    public func verify(_ loaded: LoadedCustomer) throws {
        let current = Entry(loaded)
        guard let registered = entry(directory: loaded.directory) else {
            throw LWError("\(loaded.file.path) ist nicht registriert. Ist das deine Konfiguration, bestätige sie mit: lw apply \(loaded.config.customer)")
        }
        guard registered == current else {
            throw LWError("\(loaded.file.path) weicht von der Registrierung ab (\(Self.differences(registered, current).joined(separator: ", "))). Ist das gewollt, bestätige es mit: lw apply \(loaded.config.customer)")
        }
    }

    /// What `register` would change, empty if `loaded` is registered as it is.
    public func changes(for loaded: LoadedCustomer) -> [String] {
        let current = Entry(loaded)
        guard let registered = entry(directory: loaded.directory) else {
            return ["neu: \(current.customer) in \(current.directory), Agent \(current.agent), Notizen \(current.items.joined(separator: ", "))"]
        }
        return Self.differences(registered, current)
    }

    /// Adds or replaces the entry for the folder. Two customers never share an agent or a note.
    public mutating func register(_ loaded: LoadedCustomer) throws {
        let current = Entry(loaded)
        let others = entries.filter { $0.directory != current.directory }
        for other in others {
            if other.agent == current.agent {
                throw LWError("Agent '\(current.agent)' gehört schon zu \(other.customer) (\(other.directory))")
            }
            if let shared = current.items.first(where: other.items.contains) {
                throw LWError("Notiz '\(shared)' gehört schon zu \(other.customer) (\(other.directory))")
            }
        }
        entries = others + [current]
    }

    static func differences(_ old: Entry, _ new: Entry) -> [String] {
        var result: [String] = []
        if old.customer != new.customer { result.append("customer: \(old.customer) → \(new.customer)") }
        if old.agent != new.agent { result.append("Agent: \(old.agent) → \(new.agent)") }
        if old.protonTokenItem != new.protonTokenItem { result.append("Proton-Notiz: \(old.protonTokenItem) → \(new.protonTokenItem)") }
        if old.githubTokenItem != new.githubTokenItem {
            result.append("GitHub-Notiz: \(old.githubTokenItem ?? "keine") → \(new.githubTokenItem ?? "keine")")
        }
        if old.vaults != new.vaults {
            result.append("Vaults: \(old.vaults.joined(separator: ", ")) → \(new.vaults.joined(separator: ", "))")
        }
        for name in Set(old.env.keys).union(new.env.keys).sorted() where old.env[name] != new.env[name] {
            result.append("env.\(name): \(old.env[name] ?? "–") → \(new.env[name] ?? "–")")
        }
        return result
    }
}
