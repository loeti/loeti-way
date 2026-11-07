import ArgumentParser
import Foundation
import LoetiWayKit

struct EnvCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "export-Zeilen für direnv: Tokens und env-Werte des Ordners.",
        discussion: """
        Für die .envrc: eval "$(lw env)". Liest mit dem Agent des Kunden aus dessen Vaults; dessen
        Token holt der Host-Agent (lw host) aus dem Token-Vault. Im Projektordner mit
        .loeti-way-project.yaml ersetzen dessen Tokens und env-Werte die des Kunden; ein kaputtes
        oder nicht registriertes Projekt bekommt nichts. Gesetzt wird LW_ENV_<NAME>, Asylum macht
        daraus <NAME>.

        Endet immer mit Status 0. Probleme stehen auf stderr, die betroffene Variable wird entfernt.
        Im Terminal zeigt lw env nur, was gesetzt würde; die Werte gibt es nur in eine Pipe aus.
        """
    )

    @OptionGroup var options: CommonOptions

    @Argument(help: "Ordner (Standard: aktuelles Verzeichnis, bei direnv der Ordner der .envrc).")
    var directory: String?

    mutating func run() async throws {
        let context: AppContext
        do {
            context = try AppContext.make(options)
        } catch {
            Console.error("lw env: \(error)")
            EnvExport.fallbackVariables.forEach { print("unset \($0)") }
            return
        }
        let folder = directory.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? context.cwd
        let registry: CustomerRegistry
        do {
            registry = try CustomerRegistry.load(context.global.registryFile)
        } catch {
            Console.error("lw env: \(error)")
            EnvExport.fallbackVariables.forEach { print("unset \($0)") }
            return
        }
        let result = EnvExport.build(directory: folder, global: context.global, registry: registry, sessions: context.sessions) {
            try HostToken.read(context.global.hostTokenFile)
        }
        for warning in result.warnings {
            Console.error("lw env: \(warning)")
        }
        // Values only go into a pipe (eval "$(lw env)"), never onto a screen or into a chat.
        if isatty(STDOUT_FILENO) != 0 {
            print(result.summary, terminator: "")
            Console.error("lw env: Werte ausgeblendet. Für die .envrc: eval \"$(lw env)\"")
        } else {
            print(result.shell, terminator: "")
        }
    }
}
