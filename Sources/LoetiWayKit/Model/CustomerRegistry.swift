import Foundation
import Yams

/// `~/.config/loeti-way/customers.yaml`: the customers the user has confirmed with `lw apply`.
///
/// A `.loeti-way.yaml` can lie in a folder an agent can write (a repo mounted into Asylum), and
/// it decides what `lw env` reads. So `lw env` and every command except `apply` only accept a
/// customer config that sits in a registered folder and names exactly the registered agent,
/// vaults and exports, and a project config only when its exports are registered too. The registry lives outside every project, where no container writes.
public struct CustomerRegistry: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var directory: String
        public var customer: String
        public var agent: String
        public var protonTokenItem: String
        /// `name:role` per granted vault.
        public var vaults: [String]
        /// Variable → reference the customer exports (tokens and `env`).
        public var exports: [String: String]
        /// Project folder → variable → reference of the project's own exports.
        public var projects: [String: [String: String]]

        public init(directory: String, customer: String, agent: String, protonTokenItem: String,
                    vaults: [String] = [], exports: [String: String] = [:], projects: [String: [String: String]] = [:]) {
            self.directory = directory
            self.customer = customer
            self.agent = agent
            self.protonTokenItem = protonTokenItem
            self.vaults = vaults
            self.exports = exports
            self.projects = projects
        }

        public init(_ loaded: LoadedCustomer) {
            self.init(
                directory: loaded.directory.standardizedFileURL.path,
                customer: loaded.config.customer,
                agent: loaded.config.agentName,
                protonTokenItem: loaded.config.protonTokenItem,
                vaults: loaded.config.proton.vaults.map { "\($0.name):\($0.role.rawValue)" }.sorted(),
                exports: Self.map(loaded.config.exports(directory: loaded.directory)),
                projects: Dictionary(loaded.projects.map { (Self.key($0), Self.map($0.exports)) }) { first, _ in first }
            )
        }

        static func map(_ exports: [Export]) -> [String: String] {
            Dictionary(exports.map { ($0.variable, $0.reference) }) { first, _ in first }
        }

        static func key(_ project: LoadedProject) -> String {
            project.directory.standardizedFileURL.path
        }

        enum CodingKeys: String, CodingKey {
            case directory, customer, agent, vaults, exports, projects
            case protonTokenItem = "proton_token_item"
        }

        /// Entries written before `exports` existed load, and differ until `lw apply` confirms again.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            directory = try container.decode(String.self, forKey: .directory)
            customer = try container.decode(String.self, forKey: .customer)
            agent = try container.decode(String.self, forKey: .agent)
            protonTokenItem = try container.decode(String.self, forKey: .protonTokenItem)
            vaults = try container.decodeIfPresent([String].self, forKey: .vaults) ?? []
            exports = try container.decodeIfPresent([String: String].self, forKey: .exports) ?? [:]
            projects = try container.decodeIfPresent([String: [String: String]].self, forKey: .projects) ?? [:]
        }

        /// The entry without its projects: what `verify` compares.
        var customerPart: Entry {
            var copy = self
            copy.projects = [:]
            return copy
        }

        var grantedVaults: Set<String> {
            Set(vaults.map { String($0.split(separator: ":").first ?? "") })
        }

        /// Vaults that values are read from, customer and projects.
        var exportVaults: Set<String> {
            Set(([exports] + Array(projects.values)).flatMap(\.values).compactMap { PassReference($0)?.vault })
        }
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
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        let body = try encoder.encode(File(customers: entries.sorted { $0.directory < $1.directory }))
        let text = "# Von lw apply verwaltet. Nur diese Kunden bekommen Tokens über lw env.\n" + body
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    public func entry(directory: URL) -> Entry? {
        let path = directory.standardizedFileURL.path
        return entries.first { $0.directory == path }
    }

    /// Throws unless `loaded` is registered in its folder with the same agent, vaults and
    /// exports. Its projects are checked separately (`verify(_:project:)`).
    public func verify(_ loaded: LoadedCustomer) throws {
        let current = Entry(loaded)
        guard let registered = entry(directory: loaded.directory) else {
            throw LWError("\(loaded.file.path) ist nicht registriert. Ist das deine Konfiguration, bestätige sie mit: lw apply \(loaded.config.customer)")
        }
        guard registered.customerPart == current.customerPart else {
            throw LWError("\(loaded.file.path) weicht von der Registrierung ab (\(Self.differences(registered.customerPart, current.customerPart).joined(separator: ", "))). Ist das gewollt, bestätige es mit: lw apply \(loaded.config.customer)")
        }
    }

    /// Throws unless `project` is registered with the customer as it is.
    public func verify(_ loaded: LoadedCustomer, project: LoadedProject) throws {
        let current = Entry.map(project.exports)
        switch entry(directory: loaded.directory)?.projects[Entry.key(project)] {
        case nil:
            throw LWError("\(project.file.path) ist nicht registriert. Ist das deine Konfiguration, bestätige sie mit: lw apply \(loaded.config.customer)")
        case let registered? where registered != current:
            throw LWError("\(project.file.path) weicht von der Registrierung ab. Ist das gewollt, bestätige es mit: lw apply \(loaded.config.customer)")
        default:
            break
        }
    }

    /// What `register` would change, empty if `loaded` is registered as it is.
    public func changes(for loaded: LoadedCustomer) -> [String] {
        let current = Entry(loaded)
        guard let registered = entry(directory: loaded.directory) else {
            return ["neu: \(current.customer) in \(current.directory), Agent \(current.agent), Vaults \(current.vaults.joined(separator: ", "))"]
                + Self.exportLines(current.exports, prefix: "")
                + current.projects.keys.sorted().flatMap { directory in
                    ["Projekt \(directory)"] + Self.exportLines(current.projects[directory] ?? [:], prefix: "  ")
                }
        }
        return Self.differences(registered, current)
    }

    static func exportLines(_ exports: [String: String], prefix: String) -> [String] {
        exports.keys.sorted().map { "\(prefix)  \($0) ← \(exports[$0] ?? "")" }
    }

    /// Adds or replaces the entry for the folder. Two customers never share an agent or its
    /// note, and a vault values are read from belongs to one customer only.
    public mutating func register(_ loaded: LoadedCustomer) throws {
        let current = Entry(loaded)
        let others = entries.filter { $0.directory != current.directory }
        for other in others {
            if other.agent == current.agent {
                throw LWError("Agent '\(current.agent)' gehört schon zu \(other.customer) (\(other.directory))")
            }
            if other.protonTokenItem == current.protonTokenItem {
                throw LWError("Notiz '\(current.protonTokenItem)' gehört schon zu \(other.customer) (\(other.directory))")
            }
            if let shared = current.exportVaults.intersection(other.grantedVaults).sorted().first
                ?? other.exportVaults.intersection(current.grantedVaults).sorted().first {
                throw LWError("Vault '\(shared)' ist auch \(other.customer) (\(other.directory)) freigegeben; ein Vault mit Tokens oder env-Werten gehört nur einem Kunden")
            }
        }
        entries = others + [current]
    }

    static func differences(_ old: Entry, _ new: Entry) -> [String] {
        var result: [String] = []
        if old.customer != new.customer { result.append("customer: \(old.customer) → \(new.customer)") }
        if old.agent != new.agent { result.append("Agent: \(old.agent) → \(new.agent)") }
        if old.protonTokenItem != new.protonTokenItem { result.append("Proton-Notiz: \(old.protonTokenItem) → \(new.protonTokenItem)") }
        if old.vaults != new.vaults {
            result.append("Vaults: \(old.vaults.joined(separator: ", ")) → \(new.vaults.joined(separator: ", "))")
        }
        result += exportDifferences(old.exports, new.exports, prefix: "")
        for directory in Set(old.projects.keys).union(new.projects.keys).sorted() {
            switch (old.projects[directory], new.projects[directory]) {
            case (nil, let added?):
                result += ["Projekt neu: \(directory)"] + exportLines(added, prefix: "")
            case (.some, nil):
                result.append("Projekt entfernt: \(directory)")
            case let (before?, after?):
                result += exportDifferences(before, after, prefix: "Projekt \(directory): ")
            default:
                break
            }
        }
        return result
    }

    static func exportDifferences(_ old: [String: String], _ new: [String: String], prefix: String) -> [String] {
        Set(old.keys).union(new.keys).sorted().filter { old[$0] != new[$0] }.map {
            "\(prefix)\($0): \(old[$0] ?? "–") → \(new[$0] ?? "–")"
        }
    }
}
