import ArgumentParser
import Foundation
import LoetiWayKit

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Einen Kundenordner einrichten: .loeti-way.yaml und .envrc anlegen.",
        discussion: "Bestehende Dateien bleiben unverändert. Ändert nichts in Proton Pass."
    )

    @OptionGroup var options: CommonOptions

    @Argument(help: "Kundenordner (Standard: aktuelles Verzeichnis).")
    var directory: String?

    @Option(help: "Kundenname (Standard: Name des Ordners).")
    var customer: String?

    @Option(name: .customLong("github-owner"), help: "GitHub-Organisation oder -Benutzer des Kunden. Ohne Angabe bleibt der github-Abschnitt auskommentiert.")
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
            let envrc = Scaffold.envrc(config: loaded.config, tokenVault: context.global.tokenVault)
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
          1. Vaults und Rollen in \(CustomerConfig.fileName) prüfen
          2. lw apply \(name)      Agent anlegen und Vaults freigeben
          3. lw github \(name)     GitHub-PAT anlegen und ablegen
          4. direnv allow \(folder.path)

        Einmalig für alle Kunden:

        \(Scaffold.asylumConfigSnippet)
        """)
    }
}
