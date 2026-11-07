import ArgumentParser
import Foundation
import LoetiWayKit

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Einen Kunden- oder Projektordner einrichten: Konfiguration und .envrc anlegen.",
        discussion: """
        Bestehende Dateien bleiben unverändert. Ändert nichts in Proton Pass.
        Mit --project bekommt ein Projektordner unter einem Kunden einen eigenen GitHub-PAT
        (.loeti-way-project.yaml). Ist der Ordner ein git-Repo, kommen die Dateien in .git/info/exclude.
        """
    )

    @OptionGroup var options: CommonOptions

    @Argument(help: "Kunden- bzw. Projektordner (Standard: aktuelles Verzeichnis).")
    var directory: String?

    @Flag(help: "Einen Projektordner mit eigenem GitHub-PAT einrichten statt eines Kundenordners.")
    var project = false

    @Option(help: "Kunden- bzw. Projektname (Standard: Name des Ordners).")
    var customer: String?

    @Option(name: .customLong("github-owner"), help: "GitHub-Organisation oder -Benutzer. Kunde: ohne Angabe bleibt der github-Abschnitt auskommentiert. Projekt: Standard ist der Owner des Kunden.")
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

    private func initProject(folder: URL, context: AppContext) throws {
        let fileManager = FileManager.default
        guard let customerFile = CustomerLocator.nearest(from: folder.deletingLastPathComponent()) else {
            throw LWError("Über \(folder.path) gibt es keine \(CustomerConfig.fileName). Zuerst den Kundenordner mit `lw init` einrichten.")
        }
        var loaded = try CustomerLocator.load(file: customerFile)
        let name = customer ?? folder.lastPathComponent
        if loaded.config.github == nil && githubOwner == nil {
            throw LWError("\(loaded.config.customer) hat keinen github-Abschnitt, also --github-owner angeben.")
        }

        let configFile = folder.appendingPathComponent(ProjectConfig.fileName)
        if fileManager.fileExists(atPath: configFile.path) {
            print("= \(configFile.path) gibt es schon, bleibt unverändert")
        } else {
            try Scaffold.projectTemplate(project: name, customer: loaded.config, githubOwner: githubOwner)
                .write(to: configFile, atomically: true, encoding: .utf8)
            print("+ \(configFile.path)")
            loaded = try CustomerLocator.load(file: customerFile)
        }
        if let failure = loaded.projectFailures.first(where: { $0.file.standardizedFileURL == configFile.standardizedFileURL }) {
            throw LWError(failure.message)
        }
        guard let project = loaded.project(containing: folder), project.directory.standardizedFileURL == folder.standardizedFileURL else {
            throw LWError("\(configFile.path) liegt zu tief unter \(loaded.directory.path) (höchstens 2 Ebenen)")
        }

        if !noEnvrc {
            let envrcFile = folder.appendingPathComponent(".envrc")
            let envrc = Scaffold.projectEnvrc(target: project.github, tokenVault: context.global.tokenVault)
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
          1. github-Abschnitt in \(ProjectConfig.fileName) prüfen
          2. lw github \(loaded.config.customer) --project \(project.name)   PAT anlegen und ablegen
          3. direnv allow \(folder.path)
        """)
    }
}
