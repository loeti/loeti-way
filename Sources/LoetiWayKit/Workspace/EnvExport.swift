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
        "SSH_AUTH_SOCK",
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

/// What `lw env` prints for direnv: the provider tokens and `env` values of the folder (project
/// or customer), all read by the customer's agent. Problems never stop it; they become
/// warnings, and the affected variable is unset, so a shell never keeps a stale or wider token.
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

    /// Unset when nothing is known about the folder: the providers' default variables.
    public static let fallbackVariables = TokenKind.allCases.map { EnvNaming.hostVariable($0.defaultVariable) }

    /// Lines for `eval`, values in single quotes.
    public var shell: String {
        variables.map { variable in
            switch variable.value {
            case let .set(value): "export \(variable.name)=\(Self.singleQuoted(value))"
            case .unset: "unset \(variable.name)"
            }
        }.joined(separator: "\n") + (variables.isEmpty ? "" : "\n")
    }

    /// For a terminal: which variables would be set, without the values.
    public var summary: String {
        variables.map { variable in
            switch variable.value {
            case let .set(value): "export \(variable.name)=…  (gesetzt, \(value.count) Zeichen)"
            case .unset: "unset \(variable.name)"
            }
        }.joined(separator: "\n") + (variables.isEmpty ? "" : "\n")
    }

    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `hostToken` is only read when the host agent has to log in again, and the host agent only
    /// when the customer's agent has to. Only a customer config registered in `registry` is
    /// used, and a project config only if registered too: the YAML may have been written by an agent.
    public static func build(directory: URL, global: GlobalConfig, registry: CustomerRegistry, sessions: SessionStore, hostToken: () throws -> String) -> EnvExport {
        var result = EnvExport()
        func unset(_ names: [String]) {
            for name in names where !result.variables.contains(where: { $0.name == name }) {
                result.variables.append((name, .unset))
            }
        }
        guard let file = CustomerLocator.nearest(from: directory) else {
            result.warnings.append("Kein Kunde: keine \(CustomerConfig.fileName) in \(directory.path) oder darüber")
            unset(fallbackVariables)
            return result
        }

        let customer: LoadedCustomer
        do {
            customer = try CustomerLocator.load(file: file)
            try customer.config.validate(tokenVault: global.tokenVault)
            try registry.verify(customer)
        } catch {
            result.warnings.append("\(file.path): \(error)")
            unset(fallbackVariables)
            return result
        }
        let config = customer.config
        let known = customer.variables.map(EnvNaming.hostVariable)

        // What applies here, decided before anything is read.
        let exports: [Export]
        do {
            let found = try customer.exports(for: directory)
            if let project = found.project {
                try registry.verify(customer, project: project)
            }
            exports = found.exports
        } catch {
            result.warnings.append("\(error)")
            unset(known + fallbackVariables)
            return result
        }
        guard !exports.isEmpty else {
            unset(known)
            return result
        }

        let agent: PassCLI
        do {
            agent = try sessions.customerAgent(config, tokenVault: global.tokenVault, reason: "lw env") {
                try sessions.agent(SessionStore.host, expected: global.hostAgent, token: hostToken)
            }
        } catch {
            result.warnings.append("Agent von \(config.customer): \(error)")
            unset(exports.map(\.hostVariable) + known)
            return result
        }
        for export in exports {
            let label = export.project.map { "\(config.customer) / \($0)" } ?? config.customer
            do {
                let value = try agent.with(reason: "lw env: \(export.variable) für Asylum (\(label))").read(export.reference)
                result.variables.append((export.hostVariable, .set(value)))
            } catch {
                let hint = export.token.map { " → \($0.command) oder von Hand als Notiz '\($0.itemTitle)' in '\($0.vault)' ablegen" } ?? ""
                result.warnings.append("\(export.variable): \(export.reference) nicht lesbar (\(error))\(hint)")
                result.variables.append((export.hostVariable, .unset))
            }
        }
        unset(known)
        return result
    }
}

extension SessionStore {
    private struct HostFailure: Error { let underlying: Error }

    /// The customer's agent, logged in with its token from the token vault if needed. `host`
    /// is only called for that login.
    public func customerAgent(_ config: CustomerConfig, tokenVault: String, reason: String, host: () throws -> PassCLI) throws -> PassCLI {
        do {
            return try agent(Self.agent(customer: config.customer), expected: config.agentName) {
                let reader: PassCLI
                do { reader = try host() } catch { throw HostFailure(underlying: error) }
                return try reader.with(reason: "\(reason): Agent-Token von \(config.customer)").readNote(vault: tokenVault, title: config.protonTokenItem)
            }
        } catch let failure as HostFailure {
            throw LWError("Host-Agent: \(failure.underlying) → lw host")
        } catch {
            throw LWError("\(error) → lw apply \(config.customer) bzw. lw renew \(config.customer)")
        }
    }
}
