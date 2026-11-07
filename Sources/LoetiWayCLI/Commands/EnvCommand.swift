import ArgumentParser
import Foundation
import LoetiWayKit

struct EnvCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "export-Zeilen für direnv: GitHub-PAT des Ordners und die Werte aus env:.",
        discussion: """
        Für die .envrc: eval "$(lw env)". Liest mit dem Host-Agent (lw host) aus dem Token-Vault,
        die Werte aus env: mit dem Agent des Kunden. Im Projektordner mit .loeti-way-project.yaml
        gilt dessen PAT, sonst der des Kunden; ein kaputtes Projekt bekommt keinen.

        Endet immer mit Status 0. Probleme stehen auf stderr, die betroffene Variable wird entfernt.
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
            print("unset \(Scaffold.githubVariable)")
            return
        }
        let folder = directory.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? context.cwd
        let registry: CustomerRegistry
        do {
            registry = try CustomerRegistry.load(context.global.registryFile)
        } catch {
            Console.error("lw env: \(error)")
            print("unset \(Scaffold.githubVariable)")
            return
        }
        let result = EnvExport.build(directory: folder, global: context.global, registry: registry, sessions: context.sessions) {
            try HostToken.read(context.global.hostTokenFile)
        }
        for warning in result.warnings {
            Console.error("lw env: \(warning)")
        }
        print(result.shell, terminator: "")
    }
}
