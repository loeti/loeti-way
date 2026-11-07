import ArgumentParser
import Foundation
import LoetiWayKit

struct ApplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Agent anlegen, falls er fehlt, und seine Vault-Rechte mit der Konfiguration abgleichen.",
        discussion: """
        Zeigt zuerst, was sich ändert, und fragt dann nach. Vaults, die nicht in der Konfiguration stehen, werden entzogen.
        Registriert dabei Kunde und Projekte (Agent, Vaults, was lw env liest); erst dann liest lw env etwas für sie.
        """
    )

    @OptionGroup var options: CommonOptions

    @Argument(help: "Kunde (Name oder Ordner). Ohne Angabe: .loeti-way.yaml im aktuellen Verzeichnis oder darüber.")
    var customer: String?

    @Flag(name: .customLong("dry-run"), help: "Nur anzeigen, nichts ändern.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Ohne Rückfrage ausführen.")
    var yes = false

    mutating func run() async throws {
        let context = try AppContext.make(options)
        let loaded = try context.customer(customer, registered: false)
        let config = loaded.config
        try register(loaded, context: context)
        try await context.withAccount { pass in
            try apply(config: config, variables: loaded.variables, pass: pass, context: context)
        }
    }

    /// Records the customer in customers.yaml after confirmation; only then does lw env read
    /// its notes. A change shows up here first, so a config edited by an agent can't slip through.
    private func register(_ loaded: LoadedCustomer, context: AppContext) throws {
        // Broken projects aren't registered and get nothing from lw env; say so before anything changes.
        if !loaded.projectFailures.isEmpty {
            print("Projekte mit Fehlern (werden nicht registriert, lw env setzt dort nichts):")
            for failure in loaded.projectFailures {
                print("  ! " + failure.message.replacingOccurrences(of: "\n", with: "\n    "))
            }
        }
        var registry = try CustomerRegistry.load(context.global.registryFile)
        let changes = registry.changes(for: loaded)
        guard !changes.isEmpty else { return }
        print("Registrierung (\(context.global.registryFile.path)):")
        changes.forEach { print("  \($0)") }
        if dryRun { return }
        guard yes || Console.confirm("Stimmt das, und ist \(loaded.file.path) deine Konfiguration?") else {
            print("Abgebrochen.")
            throw ExitCode.failure
        }
        try registry.register(loaded)
        try registry.save(context.global.registryFile)
        print("  ✓ registriert")
    }

    private func apply(config: CustomerConfig, variables: [String], pass: PassCLI, context: AppContext) throws {
        let store = context.store(pass)
        let agent = try pass.listAgents().first { $0.name == config.agentName }
        let actual = try agent.map { try pass.listAccess(agentID: $0.id) } ?? []
        let plan = AccessPlan.make(desired: config.proton.vaults, actual: actual)

        print("\(config.customer): Agent '\(config.agentName)'")
        if agent == nil {
            print("  + Agent anlegen (Laufzeit \(config.proton.expiration.rawValue)), Token in '\(context.global.tokenVault)' / '\(config.protonTokenItem)' ablegen")
        }
        plan.actions.forEach { print("  \($0)") }
        plan.notes.forEach { print("  ! \($0)") }
        if agent != nil && plan.isEmpty {
            print("  Nichts zu tun.")
            return
        }
        if dryRun { return }
        guard yes || Console.confirm("Ausführen?") else {
            print("Abgebrochen.")
            throw ExitCode.failure
        }

        if agent == nil {
            // Fails early if the token vault is missing, before a token exists that couldn't be stored.
            _ = try store.items()
            let token = try pass.createAgent(name: config.agentName, lifetime: config.proton.expiration)
            try context.storeToken(token, title: config.protonTokenItem, in: store)
            try? context.sessions.reset(SessionStore.agent(customer: config.customer))
            print("  ✓ Agent angelegt, Token abgelegt")
        }
        for action in plan.actions {
            switch action {
            case let .grant(vault, role):
                try pass.grant(agent: config.agentName, vault: vault, role: role)
            case let .revoke(_, shareID, _):
                try pass.revoke(agent: config.agentName, shareID: shareID)
            }
            print("  ✓ \(action)")
        }

        if agent == nil {
            print("\nAsylum reicht die Variablen von lw env in den Container. Einmalig:\n")
            print(Scaffold.asylumConfigSnippet(variables: variables))
        }
    }
}
