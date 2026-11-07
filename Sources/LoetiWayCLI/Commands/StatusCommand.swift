import ArgumentParser
import Foundation
import LoetiWayKit

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Zeigen, was Aufmerksamkeit braucht: Tokens, env, .envrc, Repos ohne passenden Token.",
        discussion: """
        Ohne Konto: Host-Agent und Agent-Tokens im Token-Vault; mit dem Agent jedes Kunden seine
        Tokens und env-Einträge, beim GitHub-Token Ablauf und welche Repos er abdeckt; .envrc,
        jedes git-Repo bis 2 Ebenen unter einem Kunden und Repos ohne Kunde.
        Ablaufdaten der Proton-Agents stammen dann von der letzten Prüfung mit dem Konto.

        Mit --konto zusätzlich die Rechte aller Agents und frische Ablaufdaten.
        Endet mit Status 1, wenn etwas zu tun ist (!).
        """
    )

    @OptionGroup var options: CommonOptions

    @Argument(help: "Nur diesen Kunden zeigen (Name oder Ordner).")
    var customer: String?

    @Flag(help: "GitHub nicht fragen (kein Ablaufdatum, keine Prüfung der Repos).")
    var offline = false

    @Flag(help: "Mit deinem Konto anmelden: Rechte der Agents und aktuelle Ablaufdaten.")
    var konto = false

    mutating func run() async throws {
        let context = try AppContext.make(options)
        let global = context.global
        var customers: [LoadedCustomer]
        var failures: [CustomerLocator.Failure] = []
        if let customer {
            customers = [try CustomerLocator.resolve(name: customer, cwd: context.cwd, root: global.root)]
        } else {
            let discovery = CustomerLocator.discover(root: global.root)
            customers = discovery.customers
            failures = discovery.failures
        }
        customers.sort { $0.config.customer.localizedCaseInsensitiveCompare($1.config.customer) == .orderedAscending }

        let host: Result<PassCLI, LWError>
        do {
            host = .success(try context.host())
        } catch let error as LWError {
            host = .failure(error)
        } catch {
            host = .failure(LWError("\(error)"))
        }
        let collector = StatusCollector(
            global: global,
            registry: try CustomerRegistry.load(global.registryFile),
            expiries: AgentExpiries.load(global.agentsFile),
            host: host,
            defaultSession: try? context.sessions.defaultSession().session(),
            checker: offline ? nil : LiveGitHubChecker(),
            agentLogin: { config in
                try context.sessions.customerAgent(config, tokenVault: global.tokenVault, reason: "lw status") { try context.host() }
            },
            now: Date()
        )

        let report: (host: StatusSection, customers: [StatusSection])
        if konto {
            let base = collector
            let all = customers
            report = try await context.withAccount { pass in
                var withAccount = base
                withAccount.account = pass
                withAccount.agents = try pass.listAgents()
                return await withAccount.collect(all)
            }
        } else {
            report = await collector.collect(customers)
        }

        var sections = [report.host] + report.customers
        sections += failures.map { StatusSection(title: $0.file.path, lines: [.todo($0.message)]) }
        if customer == nil, let orphans = StatusCollector.orphans(root: global.root) {
            sections.append(orphans)
        }
        if customers.isEmpty && failures.isEmpty {
            sections.append(StatusSection(title: "Keine Kunden unter \(global.root.path)", lines: [.info("Einen Kundenordner mit `lw init` einrichten")]))
        }
        print(sections.map { $0.render() }.joined(separator: "\n\n"))
        if sections.contains(where: \.needsAttention) {
            throw ExitCode.failure
        }
    }
}
