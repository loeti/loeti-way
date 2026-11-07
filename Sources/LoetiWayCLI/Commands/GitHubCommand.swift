import ArgumentParser
import Foundation
import LoetiWayKit

struct GitHubCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "github",
        abstract: "Einen GitHub Fine-grained PAT anlegen oder erneuern und im Token-Vault ablegen.",
        discussion: """
        GitHub hat dafür keine API. lw öffnet das Formular (vorausgefüllt aus dem github-Abschnitt)
        oder, wenn schon ein Token abgelegt ist, die Token-Liste zum Erneuern ("Regenerate token").
        Den neuen Token fügst du danach hier ein; lw prüft ihn bei GitHub und legt ihn ab.

        Ohne Kundenangabe gilt das Projekt (.loeti-way-project.yaml), in dem du gerade bist,
        sonst der PAT des Kunden. Mit Kundenangabe gilt der PAT des Kunden, ausser mit --project.
        """
    )

    @OptionGroup var options: CommonOptions
    @OptionGroup var login: LoginOptions

    @Argument(help: "Kunde (Name oder Ordner). Ohne Angabe: .loeti-way.yaml im aktuellen Verzeichnis oder darüber.")
    var customer: String?

    @Option(help: "Den PAT dieses Projekts statt des Kunden-PAT (Projektname oder Ordner).")
    var project: String?

    @Flag(name: .customLong("new"), help: "Das Formular für einen neuen Token öffnen, auch wenn schon einer abgelegt ist.")
    var createNew = false

    @Flag(name: .customLong("no-open"), help: "Die URL nur ausgeben, nicht im Browser öffnen.")
    var noOpen = false

    mutating func run() async throws {
        let context = try AppContext.make(options)
        defer { context.endSession(keep: login.keepLogin) }
        let loaded = try context.customer(customer)
        let target = try loaded.githubTarget(project: project, cwd: customer == nil ? context.cwd : nil)
        try CustomerLocator.ensureUnclaimed(target, owner: loaded, root: context.global.root)
        let github = target.settings
        print("GitHub-PAT für \(target.label)")
        try context.pass.ensureUserSession()
        let stored = try context.store.items().contains { $0.title == target.tokenItem }

        let url: URL
        if stored && !createNew {
            url = GitHubPAT.listURL
            print("Es ist schon ein Token abgelegt. Auf GitHub beim Token '\(target.tokenName)' \"Regenerate token\" wählen.")
            print("Rechte und Repos bleiben dabei erhalten. Für ein neues Formular: --new")
        } else {
            url = GitHubPAT.creationURL(target: target)
            let permissions = github.permissions.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            print("Vorausgefüllt: Name '\(target.tokenName)', Owner '\(github.owner)', \(github.expiresInDays) Tage, \(permissions).")
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
        try context.storeToken(token, title: target.tokenItem)
        print("✓ Token von @\(info.login), \(Format.expiry(info.expires, now: Date())). Abgelegt in '\(context.global.tokenVault)' / '\(target.tokenItem)'.")
        print("\n\(Scaffold.restartHint)")
    }
}
