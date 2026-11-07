import ArgumentParser
import Foundation
import LoetiWayKit

struct HostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host",
        abstract: "Den Host-Agent prüfen, einrichten oder erneuern. Er liest die Tokens für lw env.",
        discussion: """
        Der Host-Agent ist der einzige Agent mit Zugriff auf den Token-Vault, und nur als Viewer.
        Er bleibt auf dem Mac angemeldet, in einer eigenen Sitzung von lw. Sein Token liegt in
        ~/.config/loeti-way/host-token (nur für dich lesbar).

        Ohne Option: prüft Datei und Anmeldung, ohne dein Konto.
        """
    )

    @OptionGroup var options: CommonOptions

    @Flag(help: "Mit deinem Konto: Agent anlegen, falls er fehlt, und nur den Token-Vault als Viewer freigeben.")
    var setup = false

    @Flag(help: "Mit deinem Konto: Token erneuern und in host-token schreiben. Der alte wird sofort ungültig.")
    var renew = false

    @Flag(name: .customLong("set-token"), help: "Einen vorhandenen Token in host-token ablegen (Eingabe bleibt unsichtbar).")
    var setToken = false

    @Option(help: "Laufzeit beim Anlegen oder Erneuern (1w, 1m, 3m, 6m, 1y).")
    var expiration = "3m"

    @Flag(name: .shortAndLong, help: "Ohne Rückfrage ausführen.")
    var yes = false

    mutating func run() async throws {
        let context = try AppContext.make(options)
        let global = context.global
        let lifetime = try TokenLifetime.parse(expiration)
        guard [setup, renew, setToken].filter({ $0 }).count <= 1 else {
            throw ValidationError("Nur eine von --setup, --renew, --set-token.")
        }

        if setToken {
            guard let token = Console.readSecret("Token des Host-Agents (pst_…) einfügen: ")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                throw LWError("Kein Token eingegeben, nichts geändert.")
            }
            try HostToken.write(token, to: global.hostTokenFile)
            print("✓ Abgelegt in \(global.hostTokenFile.path)")
            try login(context)
            print("Rechte prüfen und einschränken: lw host --setup")
            return
        }

        if setup || renew {
            let yes = yes
            let setup = setup
            try await context.withAccount { pass in
                let agent = try pass.listAgents().first { $0.name == global.hostAgent }
                if renew {
                    guard let agent else { throw LWError("Host-Agent '\(global.hostAgent)' gibt es nicht. Zuerst: lw host --setup") }
                    print("Host-Agent '\(agent.name)', bisher \(Format.expiry(agent.expires, now: Date())). Der alte Token wird sofort ungültig.")
                    guard yes || Console.confirm("Mit Laufzeit \(lifetime.rawValue) erneuern?") else { throw ExitCode.failure }
                    try saveNewToken(try pass.renewAgent(name: agent.name, lifetime: lifetime), global: global)
                    return
                }
                guard setup else { return }
                if agent == nil {
                    print("+ Host-Agent '\(global.hostAgent)' anlegen (Laufzeit \(lifetime.rawValue)), Token in \(global.hostTokenFile.path)")
                    guard yes || Console.confirm("Anlegen?") else { throw ExitCode.failure }
                    try saveNewToken(try pass.createAgent(name: global.hostAgent, lifetime: lifetime), global: global)
                }
                let existing = try pass.listAgents().first { $0.name == global.hostAgent }
                guard let existing else { throw LWError("Host-Agent '\(global.hostAgent)' nicht gefunden") }
                let plan = AccessPlan.make(
                    desired: [VaultGrant(name: global.tokenVault, role: .viewer)],
                    actual: try pass.listAccess(agentID: existing.id),
                    allowed: { $0 == global.tokenVault }
                )
                plan.notes.forEach { print("! \($0)") }
                if plan.isEmpty {
                    print("✓ Rechte: nur '\(global.tokenVault)' als Viewer")
                } else {
                    plan.actions.forEach { print("  \($0)") }
                    guard yes || Console.confirm("Rechte so ändern?") else { throw ExitCode.failure }
                    for action in plan.actions {
                        switch action {
                        case let .grant(vault, role): try pass.grant(agent: global.hostAgent, vault: vault, role: role)
                        case let .revoke(_, shareID, _): try pass.revoke(agent: global.hostAgent, shareID: shareID)
                        }
                        print("  ✓ \(action)")
                    }
                }
            }
            try login(context)
            return
        }

        // Check only, without the account.
        _ = try HostToken.read(global.hostTokenFile)
        print("✓ \(global.hostTokenFile.path)")
        let host = try context.host()
        print("✓ Anmeldung: \(try host.session())")
        let items = try context.store(host.with(reason: "lw host: Token-Vault prüfen")).items()
        print("✓ '\(global.tokenVault)' lesbar, \(items.count) Notiz(en)")
    }

    /// The old token is already invalid: if writing fails, show the new one once.
    private func saveNewToken(_ token: String, global: GlobalConfig) throws {
        do {
            try HostToken.write(token, to: global.hostTokenFile)
            print("✓ Token in \(global.hostTokenFile.path)")
        } catch {
            Console.error("Schreiben fehlgeschlagen: \(error)")
            Console.error("Der neue Token wird nur jetzt angezeigt. Ablegen mit: lw host --set-token")
            Console.error(token)
            throw ExitCode.failure
        }
    }

    private func login(_ context: AppContext) throws {
        let host = try context.sessions.relogin(SessionStore.host, token: HostToken.read(context.global.hostTokenFile))
        print("✓ Host-Agent angemeldet: \(try host.session())")
    }
}
