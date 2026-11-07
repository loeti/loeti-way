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
        Notizen im Token-Vault ab, auf den kein Agent Zugriff hat. Die .envrc liest sie von dort.

        Globale Einstellungen: ~/.config/loeti-way/config.yaml (root, token_vault, warn_days).
        """,
        version: "0.1.0",
        subcommands: [
            StatusCommand.self,
            InitCommand.self,
            ApplyCommand.self,
            RenewCommand.self,
            GitHubCommand.self,
            AuditCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )
}

struct LoginOptions: ParsableArguments {
    @Flag(name: .customLong("keep-login"), help: "Danach bei Proton Pass angemeldet bleiben. Standard: abmelden, damit kein anderer Prozess dein Konto benutzen kann.")
    var keepLogin = false
}

struct CommonOptions: ParsableArguments {
    @Option(help: "Verzeichnis, unter dem die Kunden liegen (Standard: root aus der Konfiguration).")
    var root: String?

    @Option(name: .customLong("token-vault"), help: "Proton-Vault für die Tokens (Standard: token_vault aus der Konfiguration).")
    var tokenVault: String?
}

/// What every command needs: settings, pass-cli, the token vault.
struct AppContext {
    let global: GlobalConfig
    let pass: PassCLI

    var store: TokenStore { TokenStore(pass: pass, vault: global.tokenVault) }

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
        return AppContext(global: global, pass: PassCLI(runner: runner))
    }

    var cwd: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }

    /// Loads and validates one customer's config.
    func customer(_ name: String?) throws -> LoadedCustomer {
        let customer = try CustomerLocator.resolve(name: name, cwd: cwd, root: global.root)
        do {
            try customer.config.validate(tokenVault: global.tokenVault)
        } catch {
            throw LWError("\(customer.file.path):\n\(error)")
        }
        return customer
    }

    /// Logs out of the account after a command that needed it. The login is shared by every
    /// process of this macOS user, so an agent started outside Asylum could otherwise use it.
    func endSession(keep: Bool) {
        guard !keep, (try? pass.session())?.isAccount == true else { return }
        do {
            try pass.logout()
            Console.error("Von Proton Pass abgemeldet (--keep-login, um angemeldet zu bleiben).")
        } catch {
            Console.error("Abmelden fehlgeschlagen: \(error)\nVon Hand: pass-cli logout")
        }
    }

    /// Stores a freshly issued token. The old one is already invalid at this point, so if
    /// storing fails the token is shown once instead of being lost.
    func storeToken(_ token: String, title: String) throws {
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
