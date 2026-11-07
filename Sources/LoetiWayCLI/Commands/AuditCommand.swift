import ArgumentParser
import Foundation
import LoetiWayKit

struct AuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Zeigen, was der Agent eines Kunden gelesen hat und mit welcher Begründung."
    )

    @OptionGroup var options: CommonOptions

    @Argument(help: "Kunde (Name oder Ordner). Ohne Angabe: .loeti-way.yaml im aktuellen Verzeichnis oder darüber.")
    var customer: String?

    @Option(help: "Höchstens so viele Einträge.")
    var limit = 50

    @Flag(help: "Den Host-Agent zeigen: wer auf dem Mac Tokens geladen hat.")
    var host = false

    mutating func run() async throws {
        let context = try AppContext.make(options)
        let name = host ? context.global.hostAgent : try context.customer(customer).config.agentName
        let limit = limit
        let status = try await context.withAccount { pass in
            try pass.monitor(agent: name, limit: limit)
        }
        if status != 0 {
            throw ExitCode(status)
        }
    }
}
