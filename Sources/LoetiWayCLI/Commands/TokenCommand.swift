import ArgumentParser
import Foundation
import LoetiWayKit

struct TokenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Einen Token eines Anbieters anlegen oder erneuern und im Vault des Kunden bzw. Projekts ablegen.",
        discussion: """
        Tokens liegen im Vault des Kunden (agent-<kunde>) oder, mit 'vault: own' und eigenem
        tokens-Abschnitt, im Vault des Projekts (agent-<kunde>-<projekt>), als Notiz mit festem
        Titel pro Anbieter (GitHub: '\(TokenKind.github.itemTitle)'). Von Hand ablegen geht genauso.
        """,
        subcommands: [GitHubTokenCommand.self]
    )
}

struct GitHubTokenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "github",
        abstract: "Einen GitHub Fine-grained PAT anlegen oder erneuern und ablegen.",
        discussion: """
        GitHub hat dafür keine API. lw öffnet das Formular (vorausgefüllt aus tokens.github)
        oder, wenn schon ein Token abgelegt ist, die Token-Liste zum Erneuern ("Regenerate token").
        Den neuen Token fügst du danach hier ein; lw prüft ihn bei GitHub und legt ihn ab.

        Ohne Kundenangabe gilt der Token, den lw env im aktuellen Ordner setzt (Projekt oder
        Kunde). Mit Kundenangabe gilt der des Kunden, ausser mit --project.
        """
    )

    @OptionGroup var options: CommonOptions

    @Argument(help: "Kunde (Name oder Ordner). Ohne Angabe: .loeti-way.yaml im aktuellen Verzeichnis oder darüber.")
    var customer: String?

    @Option(help: "Den eigenen Token dieses Projekts (Projektname oder Ordner).")
    var project: String?

    @Flag(name: .customLong("new"), help: "Das Formular für einen neuen Token öffnen, auch wenn schon einer abgelegt ist.")
    var createNew = false

    @Flag(name: .customLong("no-open"), help: "Die URL nur ausgeben, nicht im Browser öffnen.")
    var noOpen = false

    mutating func run() async throws {
        let context = try AppContext.make(options)
        let loaded = try context.customer(customer)
        let target = try loaded.tokenTarget(.github, project: project, cwd: customer == nil ? context.cwd : nil)
        if let name = target.project {
            // The vault comes from an agent-writable file: only once it is confirmed.
            try CustomerRegistry.load(context.global.registryFile).verify(loaded, project: loaded.project(named: name))
        }
        guard let github = target.github else { throw LWError("\(target.label): kein GitHub-Token") }
        print("GitHub-Token für \(target.label), abgelegt in '\(target.vault)' / '\(target.itemTitle)'")
        // The customer's agent can see whether a note exists; the account is only needed to store.
        let stored = (try? context.sessions
            .customerAgent(loaded.config, tokenVault: context.global.tokenVault, reason: "lw token") { try context.host() }
            .with(reason: "lw token: vorhandenen Token suchen")
            .listItems(vault: target.vault)
            .contains { $0.isActive && $0.title == target.itemTitle }) ?? false

        let url: URL
        if stored && !createNew {
            url = GitHubPAT.listURL
            print("Es ist schon ein Token abgelegt. Auf GitHub beim Token '\(github.tokenName)' \"Regenerate token\" wählen.")
            print("Rechte und Repos bleiben dabei erhalten. Für ein neues Formular: --new")
        } else {
            url = GitHubPAT.creationURL(target: target, settings: github)
            let permissions = github.permissions.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            print("Vorausgefüllt: Name '\(github.tokenName)', Owner '\(github.owner)', \(github.expiresInDays) Tage, \(permissions).")
            if github.repositories.isEmpty {
                print("Unter \"Repository access\" die Repos auswählen (\"Only select repositories\").")
            } else {
                print("Unter \"Repository access\" → \"Only select repositories\": \(github.repositories.joined(separator: ", "))")
            }
            print("Gibt es den Token auf GitHub schon, dort stattdessen \"Regenerate token\" wählen: \(GitHubPAT.listURL.absoluteString)")
        }
        if noOpen || !Console.open(url) {
            print(url.absoluteString)
        }

        guard let token = Console.readSecret("\nNeuen Token einfügen (bleibt unsichtbar): ")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw LWError("Kein Token eingegeben, nichts geändert.")
        }
        guard GitHubPAT.isFineGrained(token) else {
            throw LWError("Das ist kein Fine-grained PAT (beginnt nicht mit github_pat_). Nichts geändert.")
        }
        let info = try await LiveGitHubChecker().check(token: token)
        try await context.withAccount { pass in
            let store = context.store(pass, vault: target.vault)
            // Fails with a hint if the vault doesn't exist yet.
            _ = try store.items()
            try context.storeToken(token, title: target.itemTitle, in: store)
        }
        print("✓ Token von @\(info.login), \(Format.expiry(info.expires, now: Date())). Abgelegt in '\(target.vault)' / '\(target.itemTitle)'.")
        print("\n\(Scaffold.restartHint)")
    }
}
