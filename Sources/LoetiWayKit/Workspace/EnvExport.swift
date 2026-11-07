import Foundation

/// `pass://<vault>/<item>/<field>`, as `pass-cli item view` takes it.
public struct PassReference: Equatable, Sendable {
    public var vault: String
    public var item: String
    public var field: String

    public init?(_ text: String) {
        guard text.hasPrefix("pass://") else { return nil }
        let parts = text.dropFirst("pass://".count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        (vault, item, field) = (parts[0], parts[1], parts[2])
    }

    public var text: String { PassCLI.reference(vault: vault, item: item, field: field) }
}

/// Names for `env:`. On the host a value is only ever exported as `LW_ENV_<NAME>`, which no
/// program reads, so a config can't inject `NODE_OPTIONS` or the like into the user's shell.
/// Asylum maps it to `<NAME>` inside the container (`env-from-host`).
public enum EnvNaming {
    public static let hostPrefix = "LW_ENV_"

    public static func hostVariable(_ name: String) -> String {
        hostPrefix + name
    }

    static let reserved: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "PWD", "IFS", "ENV", "BASH_ENV", "ZDOTDIR",
        "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "SSH_AUTH_SOCK", Scaffold.githubVariable,
    ]
    static let reservedPrefixes = ["DYLD_", "LD_", "PROTON_PASS_", "DIRENV_", "LW_", "GIT_", "ASYLUM_"]

    public static func problem(variable name: String) -> String? {
        let valid = name.first.map { $0 == "_" || ("A"..."Z").contains($0) } == true
            && name.allSatisfy { $0 == "_" || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        guard valid else { return "Variablennamen bestehen aus A-Z, 0-9 und _ und beginnen nicht mit einer Ziffer" }
        if reserved.contains(name) || reservedPrefixes.contains(where: name.hasPrefix) {
            return "'\(name)' ist reserviert"
        }
        return nil
    }
}

/// What `lw env` prints for direnv: the GitHub PAT of the folder (project or customer) and the
/// customer's `env` values. Problems never stop it; they become warnings, and the affected
/// variable is unset, so a shell never keeps a stale or wider token.
public struct EnvExport: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case set(String)
        case unset
    }

    public var variables: [(name: String, value: Value)] = []
    public var warnings: [String] = []

    public init() {}

    public static func == (lhs: EnvExport, rhs: EnvExport) -> Bool {
        lhs.warnings == rhs.warnings
            && lhs.variables.map(\.name) == rhs.variables.map(\.name)
            && lhs.variables.map(\.value) == rhs.variables.map(\.value)
    }

    /// Lines for `eval`, values in single quotes.
    public var shell: String {
        variables.map { variable in
            switch variable.value {
            case let .set(value): "export \(variable.name)=\(Self.singleQuoted(value))"
            case .unset: "unset \(variable.name)"
            }
        }.joined(separator: "\n") + (variables.isEmpty ? "" : "\n")
    }

    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `hostToken` is only read when the host agent has to log in again. Only a customer config
    /// registered in `registry` is used: the folder's YAML may have been written by an agent.
    public static func build(directory: URL, global: GlobalConfig, registry: CustomerRegistry, sessions: SessionStore, hostToken: () throws -> String) -> EnvExport {
        var result = EnvExport()
        guard let file = CustomerLocator.nearest(from: directory) else {
            result.warnings.append("Kein Kunde: keine \(CustomerConfig.fileName) in \(directory.path) oder darüber")
            result.variables.append((Scaffold.githubVariable, .unset))
            return result
        }

        let customer: LoadedCustomer
        do {
            customer = try CustomerLocator.load(file: file)
            try customer.config.validate(tokenVault: global.tokenVault)
            try registry.verify(customer)
        } catch {
            result.warnings.append("\(file.path): \(error)")
            result.variables.append((Scaffold.githubVariable, .unset))
            return result
        }
        let config = customer.config

        // Which PAT applies here, decided before anything is read.
        var target: GitHubTarget?
        var targetProblem: String?
        do {
            let found = try customer.githubTarget(project: nil, cwd: directory)
            try CustomerLocator.ensureUnclaimed(found, owner: customer, root: global.root)
            target = found
        } catch {
            // A customer without any GitHub section is not a problem, just nothing to export.
            if config.github != nil || customer.project(containing: directory) != nil || customer.projectFailure(containing: directory) != nil {
                targetProblem = "\(error)"
            }
        }

        let host: PassCLI
        do {
            host = try sessions.agent(SessionStore.host, expected: global.hostAgent, token: hostToken)
        } catch {
            result.warnings.append("Host-Agent: \(error)")
            result.variables.append((Scaffold.githubVariable, .unset))
            result.variables += config.envEntries.map { (EnvNaming.hostVariable($0.name), .unset) }
            return result
        }

        // GitHub PAT
        if let target {
            let reader = host.with(reason: "lw env: GitHub-PAT für \(target.label)")
            do {
                let token = try reader.readNote(vault: global.tokenVault, title: target.tokenItem)
                result.variables.append((Scaffold.githubVariable, .set(token)))
            } catch {
                let command = target.project.map { "lw github \(config.customer) --project \($0)" } ?? "lw github \(config.customer)"
                result.warnings.append("GitHub-PAT für \(target.label) nicht lesbar (\(error)) → \(command)")
                result.variables.append((Scaffold.githubVariable, .unset))
            }
        } else {
            if let targetProblem { result.warnings.append("GitHub-PAT: \(targetProblem)") }
            result.variables.append((Scaffold.githubVariable, .unset))
        }

        // Values from the customer's vaults, read by the customer's agent.
        let entries = config.envEntries
        guard !entries.isEmpty else { return result }
        let agentSession = SessionStore.agent(customer: config.customer)
        let agent: PassCLI
        do {
            agent = try sessions.agent(agentSession, expected: config.agentName) {
                try host.with(reason: "lw env: Agent-Token von \(config.customer) für env").readNote(vault: global.tokenVault, title: config.protonTokenItem)
            }
        } catch {
            result.warnings.append("Agent von \(config.customer): \(error) → lw apply \(config.customer) bzw. lw renew \(config.customer)")
            result.variables += entries.map { (EnvNaming.hostVariable($0.name), .unset) }
            return result
        }
        for entry in entries {
            do {
                let value = try agent.with(reason: "lw env: \(entry.name) für Asylum (\(config.customer))").read(entry.reference)
                result.variables.append((EnvNaming.hostVariable(entry.name), .set(value)))
            } catch {
                result.warnings.append("\(entry.name): \(entry.reference) nicht lesbar (\(error))")
                result.variables.append((EnvNaming.hostVariable(entry.name), .unset))
            }
        }
        return result
    }
}
