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

    mutating func run() async throws {
        let context = try AppContext.make(options)
        let config = try context.customer(customer).config
        try context.pass.ensureUserSession()
        let status = try context.pass.monitor(agent: config.agentName, limit: limit)
        if status != 0 {
            throw ExitCode(status)
        }
    }
}
