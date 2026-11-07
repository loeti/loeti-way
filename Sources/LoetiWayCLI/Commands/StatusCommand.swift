import ArgumentParser
import Foundation
import LoetiWayKit

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Ablaufdaten und Abweichungen bei den Rechten für alle Kunden zeigen.",
        discussion: "Endet mit Status 1, wenn etwas fehlt, abweicht oder bald abläuft (warn_days)."
    )

    @OptionGroup var options: CommonOptions

    @Argument(help: "Nur diesen Kunden zeigen (Name oder Ordner).")
    var customer: String?

    @Flag(help: "GitHub-Tokens nicht bei GitHub prüfen.")
    var offline = false

    mutating func run() async throws {
        let context = try AppContext.make(options)
        let customers: [LoadedCustomer]
        var failures: [CustomerLocator.Failure] = []
        if let customer {
            customers = [try CustomerLocator.resolve(name: customer, cwd: context.cwd, root: context.global.root)]
        } else {
            let discovery = CustomerLocator.discover(root: context.global.root)
            customers = discovery.customers
            failures = discovery.failures
        }
        if customers.isEmpty && failures.isEmpty {
            print("Keine Kunden unter \(context.global.root.path). Einen Kundenordner mit `lw init` einrichten.")
            return
        }

        let checker: (any GitHubTokenChecker)? = offline ? nil : LiveGitHubChecker()
        let statuses = try await context.withAccount { pass in
            try await StatusCollector(pass: pass, store: context.store(pass), checker: checker).collect(customers)
        }
        let now = Date()
        let blocks = statuses.map {
            $0.render(now: now, warnDays: context.global.warnDays, tokenVault: context.global.tokenVault)
        } + failures.map { "✗ \($0.file.path)\n  \($0.message)" }
        print(blocks.joined(separator: "\n\n"))

        let attention = statuses.contains { $0.needsAttention(now: now, warnDays: context.global.warnDays) }
        if attention || !failures.isEmpty {
            throw ExitCode.failure
        }
    }
}
