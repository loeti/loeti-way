import ArgumentParser
import Foundation
import LoetiWayKit

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Einen Kunden- oder Projektordner einrichten: Konfiguration und .envrc anlegen.",
        discussion: """
        Bestehende Dateien bleiben unverändert. Ändert nichts in Proton Pass.
        Mit --project bekommt ein Projektordner unter einem Kunden einen eigenen Vault und, wenn ein
        GitHub-Owner bekannt ist, einen eigenen GitHub-Token (.loeti-way-project.yaml). Ist der
        Ordner ein git-Repo, kommen die Dateien in .git/info/exclude.
        """
    )

    @OptionGroup var options: CommonOptions

    @Argument(help: "Kunden- bzw. Projektordner (Standard: aktuelles Verzeichnis).")
    var directory: String?

    @Flag(help: "Einen Projektordner mit eigenem Vault einrichten statt eines Kundenordners.")
    var project = false

    @Option(help: "Kundenname (Standard: Name des Ordners). Nicht mit --project: Projekte heissen wie ihr Ordner.")
    var customer: String?

    @Option(name: .customLong("github-owner"), help: "GitHub-Organisation oder -Benutzer. Ohne Angabe (und beim Projekt ohne GitHub-Token des Kunden) bleibt tokens.github auskommentiert.")
    var githubOwner: String?

    @Flag(name: .customLong("no-envrc"), help: "Keine .envrc anlegen.")
    var noEnvrc = false

    mutating func run() async throws {
        let context = try AppContext.make(options)
        let fileManager = FileManager.default
        let folder = directory.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? context.cwd
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LWError("\(folder.path) ist kein Verzeichnis")
        }
        if project {
            try initProject(folder: folder, context: context)
            return
        }

        let configFile = folder.appendingPathComponent(CustomerConfig.fileName)
        if fileManager.fileExists(atPath: configFile.path) {
            print("= \(configFile.path) gibt es schon, bleibt unverändert")
        } else {
            let name = customer ?? folder.lastPathComponent
            try Scaffold.configTemplate(customer: name, githubOwner: githubOwner)
                .write(to: configFile, atomically: true, encoding: .utf8)
            print("+ \(configFile.path)")
        }
        let loaded = try CustomerLocator.load(file: configFile)

        if !noEnvrc {
            let envrcFile = folder.appendingPathComponent(".envrc")
            let envrc = Scaffold.envrc
            if fileManager.fileExists(atPath: envrcFile.path) {
                print("= \(envrcFile.path) gibt es schon. Falls noch nicht drin, ergänzen:\n")
                print(envrc)
            } else {
                try envrc.write(to: envrcFile, atomically: true, encoding: .utf8)
                print("+ \(envrcFile.path)  (danach: direnv allow)")
            }
        }

        let name = loaded.config.customer
        print("""

        Nächste Schritte:
          1. Vaults, Rollen, tokens und env in \(CustomerConfig.fileName) prüfen
          2. Vault \(loaded.config.vault) anlegen, falls es ihn nicht gibt: pass-cli vault create --name \(loaded.config.vault)
          3. lw apply \(name)              Agent anlegen, Vaults freigeben, registrieren
          4. lw token github \(name)       GitHub-Token anlegen und ablegen (oder von Hand: Notiz '\(TokenKind.github.itemTitle)' in \(loaded.config.vault))
          5. direnv allow \(folder.path)

        Einmalig für alle Kunden: lw host --setup (Host-Agent, liest die Agent-Tokens für lw env), und

        \(Scaffold.asylumConfigSnippet(variables: loaded.variables))
        """)
    }

    private func initProject(folder: URL, context: AppContext) throws {
        let fileManager = FileManager.default
        guard let customerFile = CustomerLocator.nearest(from: folder.deletingLastPathComponent()) else {
            throw LWError("Über \(folder.path) gibt es keine \(CustomerConfig.fileName). Zuerst den Kundenordner mit `lw init` einrichten.")
        }
        var loaded = try CustomerLocator.load(file: customerFile)
        if customer != nil {
            throw LWError("--customer gibt es mit --project nicht: Der Projektname ist immer der Ordnername.")
        }
        let name = folder.lastPathComponent
        let vault = VaultNaming.projectVault(customer: loaded.config.customer, project: name)

        let configFile = folder.appendingPathComponent(ProjectConfig.fileName)
        if fileManager.fileExists(atPath: configFile.path) {
            print("= \(configFile.path) gibt es schon, bleibt unverändert")
        } else {
            try Scaffold.projectTemplate(project: name, customer: loaded.config, githubOwner: githubOwner)
                .write(to: configFile, atomically: true, encoding: .utf8)
            print("+ \(configFile.path)")
            loaded = try CustomerLocator.load(file: customerFile)
        }
        let failure = loaded.projectFailures.first { $0.file.standardizedFileURL == configFile.standardizedFileURL }
        let found = loaded.project(containing: folder).map { $0.directory.standardizedFileURL == folder.standardizedFileURL } ?? false
        if failure == nil && !found {
            throw LWError("\(configFile.path) liegt zu tief unter \(loaded.directory.path) (höchstens 2 Ebenen)")
        }

        if !noEnvrc {
            let envrcFile = folder.appendingPathComponent(".envrc")
            let envrc = Scaffold.envrc
            if fileManager.fileExists(atPath: envrcFile.path) {
                print("= \(envrcFile.path) gibt es schon. Falls noch nicht drin, ergänzen:\n")
                print(envrc)
            } else {
                try envrc.write(to: envrcFile, atomically: true, encoding: .utf8)
                print("+ \(envrcFile.path)  (danach: direnv allow)")
            }
        }
        let excluded = try Scaffold.excludeFromGit(Scaffold.projectFiles, in: folder)
        if !excluded.isEmpty {
            print("+ .git/info/exclude: \(excluded.joined(separator: ", "))")
        }

        print("""

        Nächste Schritte:
          1. tokens und env in \(ProjectConfig.fileName) prüfen
          2. In \(loaded.file.path) unter proton.vaults eintragen: - name: \(vault)
          3. Vault anlegen, falls es ihn nicht gibt: pass-cli vault create --name \(vault)
          4. lw apply \(loaded.config.customer)                          freigeben und Projekt registrieren
          5. lw token github \(loaded.config.customer) --project \(name)   GitHub-Token anlegen und ablegen
          6. direnv allow \(folder.path)
        """)
        if let failure {
            // Expected until the vault is granted; anything else is worth knowing now.
            print("\nNoch offen:\n\(failure.message)")
        }
    }
}
