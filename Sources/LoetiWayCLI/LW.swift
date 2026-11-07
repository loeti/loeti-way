import ArgumentParser
import Foundation
import LoetiWayKit

@main
struct LW: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lw",
        abstract: "Proton-Pass-Agents, Vault-Rechte und GitHub-PATs pro Kunde verwalten.",
        discussion: """
        Jeder Kundenordner hat eine .loeti-way.yaml. lw legt danach einen Proton-Pass-Agent an,
        gibt ihm genau die konfigurierten Vaults frei und legt seinen Token und den GitHub-PAT als
        Notizen im Token-Vault ab. Diesen Vault liest nur der Host-Agent (lw host): Beim Betreten
        eines Ordners setzt `lw env` (aus der .envrc) die Variablen, Asylum reicht sie weiter.

        Dein Konto meldet lw nur an, solange ein Befehl es braucht (apply, renew, github, audit,
        status), in einer eigenen Sitzung, die danach gelöscht wird.

        Globale Einstellungen: ~/.config/loeti-way/config.yaml (root, token_vault, host_agent, warn_days).
        """,
        version: "0.1.0",
        subcommands: [
            StatusCommand.self,
            EnvCommand.self,
            HostCommand.self,
            InitCommand.self,
            ApplyCommand.self,
            RenewCommand.self,
            GitHubCommand.self,
            AuditCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )
}

struct CommonOptions: ParsableArguments {
    @Option(help: "Verzeichnis, unter dem die Kunden liegen (Standard: root aus der Konfiguration).")
    var root: String?

    @Option(name: .customLong("token-vault"), help: "Proton-Vault für die Tokens (Standard: token_vault aus der Konfiguration).")
    var tokenVault: String?
}

/// What every command needs: settings and the pass-cli logins.
struct AppContext {
    let global: GlobalConfig
    let sessions: SessionStore

    func store(_ pass: PassCLI) -> TokenStore {
        TokenStore(pass: pass, vault: global.tokenVault)
    }

    /// Logs the account in (browser), runs `body`, logs out and deletes the session.
    func withAccount<T>(_ body: (PassCLI) async throws -> T) async throws -> T {
        Console.error("Anmelden mit deinem Proton-Konto (Browser) …")
        let result = try await sessions.withAccount(body)
        Console.error("Von deinem Proton-Konto abgemeldet.")
        return result
    }

    /// The host agent's login, logging in with `host-token` if needed.
    func host() throws -> PassCLI {
        try sessions.agent(SessionStore.host, expected: global.hostAgent) { try HostToken.read(global.hostTokenFile) }
    }

    static func make(_ options: CommonOptions) throws -> AppContext {
        // A child process that exits early must not kill lw while it writes to its stdin.
        signal(SIGPIPE, SIG_IGN)
        let environment = ProcessInfo.processInfo.environment
        var global = try GlobalConfig.load(environment: environment)
        if let root = options.root {
            global.root = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)
        }
        if let tokenVault = options.tokenVault {
            global.tokenVault = tokenVault
        }
        try global.validate()
        let runner = ProcessRunner(executable: environment["LW_PASS_CLI"] ?? "pass-cli")
        return AppContext(global: global, sessions: SessionStore(base: global.sessionsDirectory, runner: runner))
    }

    var cwd: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }

    /// Loads and validates one customer's config. Unless `registered` is false (only `apply`,
    /// which registers), it must match `customers.yaml`.
    func customer(_ name: String?, registered: Bool = true) throws -> LoadedCustomer {
        let customer = try CustomerLocator.resolve(name: name, cwd: cwd, root: global.root)
        do {
            try customer.config.validate(tokenVault: global.tokenVault)
            if customer.config.agentName == global.hostAgent {
                throw LWError("Agent '\(global.hostAgent)' ist der Host-Agent und kann nicht zu einem Kunden gehören")
            }
        } catch {
            throw LWError("\(customer.file.path):\n\(error)")
        }
        if registered {
            try CustomerRegistry.load(global.registryFile).verify(customer)
        }
        return customer
    }

    /// Stores a freshly issued token. The old one is already invalid at this point, so if
    /// storing fails the token is shown once instead of being lost.
    func storeToken(_ token: String, title: String, in store: TokenStore) throws {
        do {
            try store.save(title: title, token: token)
        } catch {
            Console.error("Speichern in '\(global.tokenVault)' fehlgeschlagen: \(error)")
            Console.error("Der neue Token wird nur jetzt angezeigt. Lege ihn von Hand als Notiz '\(title)' ab:")
            Console.error(token)
            throw ExitCode.failure
        }
    }
}
