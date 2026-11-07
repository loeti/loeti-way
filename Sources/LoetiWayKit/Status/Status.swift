import Foundation

/// One finding of `lw status`.
public struct StatusLine: Equatable, Sendable {
    public enum Level: Equatable, Sendable { case ok, info, attention }

    public var level: Level
    public var text: String

    public static func ok(_ text: String) -> StatusLine { StatusLine(level: .ok, text: text) }
    public static func info(_ text: String) -> StatusLine { StatusLine(level: .info, text: text) }
    public static func todo(_ text: String) -> StatusLine { StatusLine(level: .attention, text: text) }

    var symbol: String {
        switch level {
        case .ok: "✓"
        case .info: "·"
        case .attention: "!"
        }
    }
}

/// The host agent, one customer, or the repositories outside every customer.
public struct StatusSection: Equatable, Sendable {
    public var title: String
    public var lines: [StatusLine]

    public init(title: String, lines: [StatusLine] = []) {
        self.title = title
        self.lines = lines
    }

    public var needsAttention: Bool { lines.contains { $0.level == .attention } }

    public func render() -> String {
        let indent = "\n    "
        return (["\(needsAttention ? "!" : "✓") \(title)"]
            + lines.map { "  \($0.symbol) \($0.text.replacingOccurrences(of: "\n", with: indent))" })
            .joined(separator: "\n")
    }
}

/// Gathers what `lw status` shows. Without `account` everything comes from the host agent (agent
/// tokens), the customers' agents (provider tokens, `env` items), GitHub and the file system;
/// agents' grants and fresh expiry dates need the account.
public struct StatusCollector {
    public var global: GlobalConfig
    public var registry: CustomerRegistry
    public var expiries: AgentExpiries
    /// The host agent's login, or why there is none.
    public var host: Result<PassCLI, LWError>
    /// pass-cli's default session, as every process sees it.
    public var defaultSession: PassSession?
    /// With `--konto`: the account's login and the agents it sees.
    public var account: PassCLI?
    public var agents: [ProtonAgent]?
    /// nil with `--offline`.
    public var checker: (any GitHubTokenChecker)?
    /// Logs in a customer's agent (`SessionStore.customerAgent`).
    public var agentLogin: (CustomerConfig) throws -> PassCLI
    public var now: Date

    public init(global: GlobalConfig, registry: CustomerRegistry, expiries: AgentExpiries, host: Result<PassCLI, LWError>,
                defaultSession: PassSession?, account: PassCLI? = nil, agents: [ProtonAgent]? = nil,
                checker: (any GitHubTokenChecker)?, agentLogin: @escaping (CustomerConfig) throws -> PassCLI, now: Date) {
        self.global = global
        self.registry = registry
        self.expiries = expiries
        self.host = host
        self.defaultSession = defaultSession
        self.account = account
        self.agents = agents
        self.checker = checker
        self.agentLogin = agentLogin
        self.now = now
    }

    private var store: TokenStore? {
        (try? host.get()).map { TokenStore(pass: $0.with(reason: "lw status: Agent-Tokens prüfen"), vault: global.tokenVault) }
    }

    // MARK: Host

    public func hostSection(items: [VaultItem]?) -> StatusSection {
        var section = StatusSection(title: "Host-Agent \(global.hostAgent)")
        switch host {
        case .success:
            section.lines.append(.ok("angemeldet, liest '\(global.tokenVault)'" + (items.map { " (\($0.count) Notizen)" } ?? "")))
            if items == nil {
                section.lines.append(.todo("'\(global.tokenVault)' nicht lesbar → lw host --setup"))
            }
        case let .failure(error):
            section.lines.append(.todo("\(error)"))
        }
        section.lines.append(expiryLine("Token", agent: global.hostAgent))

        if let account, let agent = agents?.first(where: { $0.name == global.hostAgent }) {
            do {
                let plan = AccessPlan.make(
                    desired: [VaultGrant(name: global.tokenVault, role: .viewer)],
                    actual: try account.listAccess(agentID: agent.id),
                    allowed: { $0 == global.tokenVault }
                )
                section.lines += plan.isEmpty
                    ? [.ok("Rechte: nur '\(global.tokenVault)' als Viewer")]
                    : [.todo("Rechte weichen ab → lw host --setup")] + plan.actions.map { .info("\($0)") }
            } catch {
                section.lines.append(.todo("Rechte nicht lesbar: \(error)"))
            }
        } else if agents != nil {
            section.lines.append(.todo("Host-Agent fehlt in Proton → lw host --setup"))
        }

        switch defaultSession {
        case .account?:
            section.lines.append(.todo("Dein Konto ist in der normalen pass-cli-Anmeldung angemeldet, jeder Prozess kann es benutzen → pass-cli logout"))
        case let .token(name)?:
            section.lines.append(.info("Normale pass-cli-Anmeldung: Agent '\(name ?? "?")'"))
        case .loggedOut?:
            section.lines.append(.ok("Normale pass-cli-Anmeldung leer"))
        case nil:
            break
        }
        return section
    }

    /// The expiry of an agent's token: from the account if logged in, else as last recorded.
    func expiryLine(_ label: String, agent name: String) -> StatusLine {
        if let agents {
            guard let agent = agents.first(where: { $0.name == name }) else { return .info("\(label): Agent '\(name)' fehlt") }
            return dated("\(label) (\(name))", agent.expires, recorded: false)
        }
        guard let date = expiries.expires[name] else {
            return .info("\(label) (\(name)): Ablauf unbekannt → lw status --konto")
        }
        return dated("\(label) (\(name))", date, recorded: true)
    }

    private func dated(_ label: String, _ date: Date?, recorded: Bool) -> StatusLine {
        let suffix = recorded ? expiries.checked.map { " (Stand \(Format.date($0)))" } ?? "" : ""
        let text = "\(label): \(Format.expiry(date, now: now))\(suffix)"
        guard let date else { return .ok(text) }
        return Format.daysLeft(until: date, now: now) <= global.warnDays ? .todo(text) : .ok(text)
    }

    // MARK: Customers

    public func collect(_ customers: [LoadedCustomer]) async -> (host: StatusSection, customers: [StatusSection]) {
        let items = try? store?.items()
        var sections: [StatusSection] = []
        for customer in customers {
            sections.append(await section(for: customer, tokenItems: items))
        }
        return (hostSection(items: items), sections)
    }

    /// Reads with a customer's agent: logs in once, lists each vault once, reads each value once.
    final class AgentReader {
        let login: () throws -> PassCLI
        var agent: Result<PassCLI, LWError>?
        var lists: [String: Result<[VaultItem], LWError>] = [:]
        var values: [String: String?] = [:]

        init(login: @escaping () throws -> PassCLI) {
            self.login = login
        }

        func pass() -> Result<PassCLI, LWError> {
            if let agent { return agent }
            let result: Result<PassCLI, LWError>
            do {
                result = .success(try login().with(reason: "lw status: Tokens und env prüfen"))
            } catch let error as LWError {
                result = .failure(error)
            } catch {
                result = .failure(LWError("\(error)"))
            }
            agent = result
            return result
        }

        func contains(vault: String, title: String) -> Result<Bool, LWError> {
            let list = lists[vault] ?? pass().flatMap { pass in
                Result { try pass.listItems(vault: vault).filter(\.isActive) }.mapError { LWError("Vault '\(vault)' nicht lesbar: \($0)") }
            }
            lists[vault] = list
            return list.map { $0.contains { $0.title == title } }
        }

        func value(_ reference: String) -> String? {
            if let cached = values[reference] { return cached }
            let value = try? pass().get().read(reference)
            values[reference] = value
            return value
        }
    }

    func section(for customer: LoadedCustomer, tokenItems: [VaultItem]?) async -> StatusSection {
        let config = customer.config
        let name = config.customer
        var section = StatusSection(title: "\(name)  \(customer.directory.path)")

        // An unconfirmed config may have been written by an agent: nothing it names is read.
        var confirmed = true
        do {
            try config.validate(tokenVault: global.tokenVault)
            try registry.verify(customer)
        } catch {
            section.lines.append(.todo("\(error)"))
            confirmed = false
        }

        // Proton agent
        if let agents {
            if let agent = agents.first(where: { $0.name == config.agentName }), let account {
                section.lines.append(dated("Agent \(agent.name)", agent.expires, recorded: false))
                do {
                    let plan = AccessPlan.make(desired: config.proton.vaults, actual: try account.listAccess(agentID: agent.id))
                    section.lines += plan.isEmpty
                        ? [.ok("Rechte wie konfiguriert")]
                        : [.todo("Rechte: \(plan.actions.count) Änderung(en) offen → lw apply \(name)")] + plan.actions.map { .info("\($0)") }
                    section.lines += plan.notes.map { .info($0) }
                } catch {
                    section.lines.append(.todo("Rechte nicht lesbar: \(error)"))
                }
            } else {
                section.lines.append(.todo("Agent '\(config.agentName)' fehlt → lw apply \(name)"))
            }
        } else {
            section.lines.append(expiryLine("Agent", agent: config.agentName))
        }
        if let tokenItems, !tokenItems.contains(where: { $0.title == config.protonTokenItem }) {
            section.lines.append(.todo("Token des Agents fehlt in '\(global.tokenVault)' / '\(config.protonTokenItem)' → lw apply \(name) bzw. lw renew \(name)"))
        }

        section.lines.append(envrcLine(customer.directory, label: ".envrc"))
        guard confirmed else {
            section.lines.append(.info("Tokens, env und Repos nicht geprüft, solange die Konfiguration nicht bestätigt ist"))
            return section
        }

        let reader = AgentReader { [agentLogin] in try agentLogin(config) }
        let exports = config.exports(directory: customer.directory)
        let hasExports = !exports.isEmpty || customer.projects.contains { !$0.exports.isEmpty }
        var readable = true
        if hasExports, case let .failure(error) = reader.pass() {
            section.lines.append(.todo("Agent-Anmeldung: \(error)"))
            section.lines.append(.info("Tokens und env nicht prüfbar"))
            readable = false
        }
        if readable {
            section.lines += await exportLines(exports, prefix: "", reader: reader)
        }

        var unregistered: Set<String> = []
        for project in customer.projects {
            do {
                try registry.verify(customer, project: project)
                if readable {
                    section.lines += await exportLines(project.exports, prefix: "\(project.name): ", reader: reader)
                }
            } catch {
                unregistered.insert(project.directory.standardizedFileURL.path)
                section.lines.append(.todo("\(project.name): \(error)"))
            }
            section.lines.append(envrcLine(project.directory, label: "\(project.name): .envrc"))
        }
        for failure in customer.projectFailures {
            section.lines.append(.todo(failure.message))
        }

        // Every working copy below the customer
        for repository in GitRepository.find(below: customer.directory, maxDepth: 2) {
            section.lines += await repositoryLines(repository, customer: customer, unregistered: unregistered,
                                                   reader: readable ? reader : nil)
        }
        return section
    }

    func envrcLine(_ directory: URL, label: String) -> StatusLine {
        switch EnvrcState.check(directory) {
        case .current: .ok("\(label) lädt lw env")
        case .missing: .todo("\(label) fehlt → eval \"$(lw env)\" eintragen, dann direnv allow")
        case .outdated: .todo("\(label) liest noch selbst mit pass-cli → Inhalt ersetzen: eval \"$(lw env)\", dann direnv allow")
        case .own: .todo("\(label) lädt lw env nicht → eval \"$(lw env)\" eintragen")
        }
    }

    /// One line per token, one for all `env` items that exist, one per missing item.
    func exportLines(_ exports: [Export], prefix: String, reader: AgentReader) async -> [StatusLine] {
        var lines: [StatusLine] = []
        var present: [String] = []
        for export in exports {
            if let target = export.token {
                lines.append(await tokenLine(target, label: "\(prefix)\(target.kind.label)", reader: reader))
                continue
            }
            guard let reference = PassReference(export.reference) else { continue }
            switch reader.contains(vault: reference.vault, title: reference.item) {
            case .success(true): present.append(export.variable)
            case .success(false): lines.append(.todo("\(prefix)env \(export.variable): Eintrag '\(reference.item)' fehlt in '\(reference.vault)'"))
            case let .failure(error): lines.append(.info("\(prefix)env \(export.variable): nicht prüfbar (\(error))"))
            }
        }
        if !present.isEmpty {
            lines.append(.ok("\(prefix)env: \(present.joined(separator: ", "))"))
        }
        return lines
    }

    func tokenLine(_ target: TokenTarget, label: String, reader: AgentReader) async -> StatusLine {
        let command = target.command
        switch reader.contains(vault: target.vault, title: target.itemTitle) {
        case let .failure(error): return .info("\(label): nicht prüfbar (\(error))")
        case .success(false): return .todo("\(label): Token fehlt in '\(target.vault)' / '\(target.itemTitle)' → \(command)")
        case .success(true): break
        }
        guard let checker, target.github != nil else { return .ok("\(label): Token abgelegt (nicht geprüft)") }
        guard let token = reader.value(target.reference) else { return .todo("\(label): Token nicht lesbar → \(command)") }
        do {
            let info = try await checker.check(token: token)
            let line = dated("\(label) @\(info.login)", info.expires, recorded: false)
            return line.level == .attention ? .todo(line.text + " → \(command)") : line
        } catch {
            return .todo("\(label): \(error) → \(command)")
        }
    }

    /// `reader` is nil when the customer's agent couldn't log in.
    func repositoryLines(_ repository: GitRepository, customer: LoadedCustomer, unregistered: Set<String>, reader: AgentReader?) async -> [StatusLine] {
        let relative = Self.relative(repository.directory, to: customer.directory)
        guard let found = try? customer.exports(for: repository.directory) else { return [] }  // broken project, reported above
        if let project = found.project, unregistered.contains(project.directory.standardizedFileURL.path) { return [] }
        var lines: [StatusLine] = []

        if found.project == nil {
            // Its own .envrc wins over the customer's; it must call lw env or chain up.
            switch EnvrcState.check(repository.directory) {
            case .missing, .current, .own(chainsUp: true): break
            case .outdated, .own(chainsUp: false):
                lines.append(.todo("\(relative): eigene .envrc lädt lw env nicht → eval \"$(lw env)\" eintragen"))
            }
        }

        guard let github = repository.github else {
            lines.append(.info("\(relative): kein GitHub-origin\(repository.origin.map { " (\($0))" } ?? "")"))
            return lines
        }
        guard let target = found.exports.compactMap(\.token).first(where: { $0.kind == .github }), let settings = target.github else {
            lines.append(.todo("\(relative): \(github) ohne GitHub-Token → 'tokens.github' in \(CustomerConfig.fileName) oder lw init --project \(repository.directory.path)"))
            return lines
        }
        guard let checker, let token = reader?.value(target.reference) else {
            if found.project != nil { lines.append(.ok("\(relative): \(github)")) }
            return lines
        }
        do {
            if try await checker.canAccess(token: token, repository: github) {
                if found.project != nil { lines.append(.ok("\(relative): \(github), Token deckt es ab")) }
            } else {
                lines.append(.todo("\(relative): GitHub-Token '\(settings.tokenName)' (\(target.label)) deckt \(github) nicht ab → auf GitHub beim Token unter \"Repository access\" ergänzen"))
            }
        } catch {
            lines.append(.todo("\(relative): \(github) nicht prüfbar: \(error)"))
        }
        return lines
    }

    // MARK: Outside customers

    /// Working copies below the root that belong to no customer: they get no tokens.
    public static func orphans(root: URL, maxDepth: Int = 3) -> StatusSection? {
        let repositories = GitRepository.find(below: root, maxDepth: maxDepth) { folder in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(CustomerConfig.fileName).path)
        }
        guard !repositories.isEmpty else { return nil }
        return StatusSection(title: "Ohne Kunde  \(root.path)", lines: repositories.map { repository in
            .todo("\(relative(repository.directory, to: root))\(repository.github.map { " (\($0))" } ?? ""): unter einen Kundenordner verschieben oder lw init")
        })
    }

    static func relative(_ url: URL, to base: URL) -> String {
        let path = url.standardizedFileURL.path
        let prefix = base.standardizedFileURL.path
        if path == prefix { return "." }
        return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count + 1)) : path
    }
}
