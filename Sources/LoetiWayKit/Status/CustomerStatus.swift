import Foundation

public struct CustomerStatus: Sendable {
    public enum GitHubState: Equatable, Sendable {
        case notConfigured
        case tokenMissing
        case notChecked
        case ok(GitHubTokenInfo)
        case failed(String)
    }

    public var customer: LoadedCustomer
    public var configError: String?
    public var agent: ProtonAgent?
    /// nil if the token vault couldn't be listed.
    public var protonTokenStored: Bool?
    /// nil if the agent is missing or its grants couldn't be read.
    public var plan: AccessPlan?
    public var accessError: String?
    /// The customer-wide PAT.
    public var github: GitHubState = .notConfigured
    /// Project PATs, in the order of `customer.projects`.
    public var projects: [(name: String, state: GitHubState)] = []

    public init(customer: LoadedCustomer) {
        self.customer = customer
    }

    public func needsAttention(now: Date, warnDays: Int) -> Bool {
        func expiresSoon(_ date: Date?) -> Bool {
            guard let date else { return false }
            return Format.daysLeft(until: date, now: now) <= warnDays
        }
        if configError != nil || accessError != nil || agent == nil { return true }
        if !customer.projectFailures.isEmpty { return true }
        if protonTokenStored == false || plan?.isEmpty == false { return true }
        if expiresSoon(agent?.expires) { return true }
        return ([github] + projects.map(\.state)).contains { state in
            switch state {
            case .notConfigured, .notChecked: false
            case .tokenMissing, .failed: true
            case let .ok(info): expiresSoon(info.expires)
            }
        }
    }

    public func render(now: Date, warnDays: Int, tokenVault: String) -> String {
        let config = customer.config
        let name = config.customer
        var lines = ["\(needsAttention(now: now, warnDays: warnDays) ? "!" : "✓") \(name)  \(customer.directory.path)"]
        if let configError {
            lines.append("  Konfiguration: \(configError.replacingOccurrences(of: "\n", with: "\n    "))")
        }

        if let agent {
            lines.append("  Proton  \(agent.name): \(Format.expiry(agent.expires, now: now))")
            if let plan {
                if plan.isEmpty {
                    lines.append("          Rechte: wie konfiguriert")
                } else {
                    lines.append("          Rechte: \(plan.actions.count) Änderung(en) offen → lw apply \(name)")
                    lines.append(contentsOf: plan.actions.map { "            \($0)" })
                }
                lines.append(contentsOf: plan.notes.map { "          ! \($0)" })
            } else if let accessError {
                lines.append("          Rechte nicht lesbar: \(accessError)")
            }
        } else {
            lines.append("  Proton  Agent '\(config.agentName)' fehlt → lw apply \(name)")
        }
        switch protonTokenStored {
        case true?: break
        case false?: lines.append("          Token fehlt in '\(tokenVault)' / '\(config.protonTokenItem)' → lw renew \(name)")
        case nil: lines.append("          Token-Vault '\(tokenVault)' nicht lesbar")
        }

        func line(_ state: GitHubState, label: String, item: String, command: String) -> String {
            switch state {
            case .notConfigured: "  GitHub  \(label)nicht konfiguriert"
            case .tokenMissing: "  GitHub  \(label)Token fehlt in '\(tokenVault)' / '\(item)' → \(command)"
            case .notChecked: "  GitHub  \(label)Token gespeichert (nicht geprüft)"
            case let .ok(info): "  GitHub  \(label)@\(info.login): \(Format.expiry(info.expires, now: now))"
            case let .failed(message): "  GitHub  \(label)\(message) → \(command)"
            }
        }
        if config.github != nil || (projects.isEmpty && customer.projectFailures.isEmpty) {
            lines.append(line(github, label: "", item: config.githubTokenItem, command: "lw github \(name)"))
        }
        for (project, (_, state)) in zip(customer.projects, projects) {
            lines.append(line(state, label: "\(project.name): ", item: project.github.tokenItem, command: "lw github \(name) --project \(project.name)"))
        }
        for failure in customer.projectFailures {
            lines.append("  ✗ \(failure.message.replacingOccurrences(of: "\n", with: "\n    "))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Gathers the state of several customers with as few pass-cli calls as possible.
public struct StatusCollector {
    public var pass: PassCLI
    public var store: TokenStore
    public var checker: (any GitHubTokenChecker)?

    public init(pass: PassCLI, store: TokenStore, checker: (any GitHubTokenChecker)?) {
        self.pass = pass
        self.store = store
        self.checker = checker
    }

    public func collect(_ customers: [LoadedCustomer]) async throws -> [CustomerStatus] {
        let agents = try pass.listAgents()
        let items = try? store.items()
        var result: [CustomerStatus] = []

        for customer in customers {
            let config = customer.config
            var status = CustomerStatus(customer: customer)
            do {
                try config.validate(tokenVault: store.vault)
            } catch {
                status.configError = "\(error)"
            }

            status.agent = agents.first { $0.name == config.agentName }
            status.protonTokenStored = items.map { $0.contains { $0.title == config.protonTokenItem } }
            if let agent = status.agent {
                do {
                    status.plan = AccessPlan.make(desired: config.proton.vaults, actual: try pass.listAccess(agentID: agent.id))
                } catch {
                    status.accessError = "\(error)"
                }
            }

            status.github = config.github == nil ? .notConfigured : await githubState(item: config.githubTokenItem, items: items)
            for project in customer.projects {
                status.projects.append((project.name, await githubState(item: project.github.tokenItem, items: items)))
            }
            result.append(status)
        }
        return result
    }

    private func githubState(item: String, items: [VaultItem]?) async -> CustomerStatus.GitHubState {
        if let items, !items.contains(where: { $0.title == item }) {
            return .tokenMissing
        }
        guard let checker else { return .notChecked }
        do {
            return .ok(try await checker.check(token: try store.read(title: item)))
        } catch {
            return .failed("\(error)")
        }
    }
}
