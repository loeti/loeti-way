import ArgumentParser
import Foundation
import LoetiWayKit

struct RenewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "renew",
        abstract: "Den Token des Proton-Agents erneuern und im Token-Vault ablegen.",
        discussion: "Der alte Token wird sofort ungültig. Die Vault-Rechte bleiben erhalten."
    )

    @OptionGroup var options: CommonOptions

    @Argument(help: "Kunde (Name oder Ordner). Ohne Angabe: .loeti-way.yaml im aktuellen Verzeichnis oder darüber.")
    var customer: String?

    @Option(help: "Laufzeit (1w, 1m, 3m, 6m, 1y). Standard: proton.expiration aus der Konfiguration.")
    var expiration: String?

    @Flag(name: .shortAndLong, help: "Ohne Rückfrage ausführen.")
    var yes = false

    mutating func run() async throws {
        let context = try AppContext.make(options)
        let config = try context.customer(customer).config
        let lifetime = try expiration.map(TokenLifetime.parse) ?? config.proton.expiration
        let pass = context.pass
        try pass.ensureUserSession()

        guard let agent = try pass.listAgents().first(where: { $0.name == config.agentName }) else {
            throw LWError("Agent '\(config.agentName)' gibt es nicht. Zuerst: lw apply \(config.customer)")
        }
        _ = try context.store.items()

        print("\(config.customer): Agent '\(agent.name)', bisher \(Format.expiry(agent.expires, now: Date()))")
        print("Der alte Token wird sofort ungültig. Laufende Asylum-Container von \(config.customer) verlieren den Zugriff auf Proton Pass.")
        guard yes || Console.confirm("Mit Laufzeit \(lifetime.rawValue) erneuern?") else {
            print("Abgebrochen.")
            throw ExitCode.failure
        }

        let token = try pass.renewAgent(name: agent.name, lifetime: lifetime)
        try context.storeToken(token, title: config.protonTokenItem)
        let renewed = try? pass.listAgents().first { $0.name == agent.name }
        print("✓ Erneuert, \(Format.expiry(renewed?.expires, now: Date())). Abgelegt in '\(context.global.tokenVault)' / '\(config.protonTokenItem)'.")
        print("\n\(Scaffold.restartHint)")
    }
}
