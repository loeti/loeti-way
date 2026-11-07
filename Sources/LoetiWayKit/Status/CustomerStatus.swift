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
    public var github: GitHubState = .notConfigured

    public init(customer: LoadedCustomer) {
        self.customer = customer
    }

    public func needsAttention(now: Date, warnDays: Int) -> Bool {
        func expiresSoon(_ date: Date?) -> Bool {
            guard let date else { return false }
            return Format.daysLeft(until: date, now: now) <= warnDays
        }
        if configError != nil || accessError != nil || agent == nil { return true }
        if protonTokenStored == false || plan?.isEmpty == false { return true }
        if expiresSoon(agent?.expires) { return true }
        switch github {
        case .notConfigured, .notChecked: return false
        case .tokenMissing, .failed: return true
        case let .ok(info): return expiresSoon(info.expires)
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

        switch github {
        case .notConfigured:
            lines.append("  GitHub  nicht konfiguriert")
        case .tokenMissing:
            lines.append("  GitHub  Token fehlt in '\(tokenVault)' / '\(config.githubTokenItem)' → lw github \(name)")
        case .notChecked:
            lines.append("  GitHub  Token gespeichert (nicht geprüft)")
        case let .ok(info):
            lines.append("  GitHub  @\(info.login): \(Format.expiry(info.expires, now: now))")
        case let .failed(message):
            lines.append("  GitHub  \(message) → lw github \(name)")
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

            if config.github == nil {
                status.github = .notConfigured
            } else if let items, !items.contains(where: { $0.title == config.githubTokenItem }) {
                status.github = .tokenMissing
            } else if let checker {
                do {
                    let token = try store.read(title: config.githubTokenItem)
                    status.github = .ok(try await checker.check(token: token))
                } catch {
                    status.github = .failed("\(error)")
                }
            } else {
                status.github = .notChecked
            }
            result.append(status)
        }
        return result
    }
}
