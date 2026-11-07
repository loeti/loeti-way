import Foundation
import Testing
@testable import LoetiWayKit

@Suite("Status")
struct StatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func days(_ count: Double) -> Date { now.addingTimeInterval(count * 86_400) }

    static func repo(_ directory: URL, origin: String?) throws {
        let config = origin.map { "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = \($0)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n" } ?? "[core]\n"
        try Fixtures.write(config, to: directory.appendingPathComponent(".git/config"))
    }

    /// root/customers/KundeA with
    /// - web: repo with project PAT and .envrc
    /// - api: repo without project, covered by the customer PAT
    /// - legacy: repo without project, own outdated .envrc, not covered
    /// - notes: repo without origin
    /// and root/other/tool, a repo outside every customer.
    func makeTree() throws -> (root: URL, customer: URL, global: GlobalConfig) {
        let root = try Fixtures.temporaryDirectory()
        let customer = root.appendingPathComponent("customers/KundeA")
        try Fixtures.write(Fixtures.kundeA, to: customer.appendingPathComponent(CustomerConfig.fileName))
        try Fixtures.write(Scaffold.envrc, to: customer.appendingPathComponent(".envrc"))

        try Self.repo(customer.appendingPathComponent("web"), origin: "git@github.com:kundea-org/web.git")
        try Fixtures.write("{}\n", to: customer.appendingPathComponent("web/\(ProjectConfig.fileName)"))
        try Fixtures.write(Scaffold.envrc, to: customer.appendingPathComponent("web/.envrc"))

        try Self.repo(customer.appendingPathComponent("api"), origin: "https://github.com/kundea-org/api")
        try Self.repo(customer.appendingPathComponent("legacy"), origin: "ssh://git@github.com/kundea-org/legacy.git")
        try Fixtures.write("export ASYLUM_GH_TOKEN=\"$(pass-cli item view \"pass://lw-tokens/x/note\")\"\n", to: customer.appendingPathComponent("legacy/.envrc"))
        try Self.repo(customer.appendingPathComponent("notes"), origin: nil)

        try Self.repo(root.appendingPathComponent("other/tool"), origin: "git@github.com:loeti/tool.git")
        return (root, customer, GlobalConfig(root: root, environment: ["HOME": root.path]))
    }

    func hostRunner() -> FakeRunner {
        let runner = FakeRunner()
        runner.on(["item", "list"], stdout: """
        {"items": [{"id": "1", "share_id": "t", "title": "KundeA Proton Agent"},
                   {"id": "2", "share_id": "t", "title": "KundeA GitHub PAT"},
                   {"id": "3", "share_id": "t", "title": "KundeA web GitHub PAT"}]}
        """)
        runner.on(["item", "view", "pass://lw-tokens/KundeA GitHub PAT/note"], stdout: "github_pat_customer\n")
        runner.on(["item", "view", "pass://lw-tokens/KundeA web GitHub PAT/note"], stdout: "github_pat_web\n")
        return runner
    }

    func collector(_ tree: (root: URL, customer: URL, global: GlobalConfig), runner: FakeRunner, registered: Bool = true,
                   checker: (any GitHubTokenChecker)?, defaultSession: PassSession = .loggedOut) throws -> (StatusCollector, LoadedCustomer) {
        let customer = try CustomerLocator.load(file: tree.customer.appendingPathComponent(CustomerConfig.fileName))
        var registry = CustomerRegistry()
        if registered { try registry.register(customer) }
        let collector = StatusCollector(
            global: tree.global,
            registry: registry,
            expiries: AgentExpiries(expires: ["asylum-kundea": days(5), "lw-host": days(60)], checked: days(-1)),
            host: .success(PassCLI(runner: runner, sessionDirectory: URL(fileURLWithPath: "/s/host"))),
            defaultSession: defaultSession,
            checker: checker,
            now: now
        )
        return (collector, customer)
    }

    var checker: FakeChecker {
        FakeChecker(
            result: .success(GitHubTokenInfo(login: "loeti", expires: days(60))),
            access: ["github_pat_web": ["kundea-org/web"], "github_pat_customer": ["kundea-org/api"]]
        )
    }

    func texts(_ section: StatusSection, _ level: StatusLine.Level) -> [String] {
        section.lines.filter { $0.level == level }.map(\.text)
    }

    @Test("without the account: tokens, .envrc and every repository, from the host agent and GitHub")
    func overview() async throws {
        let tree = try makeTree()
        let runner = hostRunner()
        let (collector, customer) = try collector(tree, runner: runner, checker: checker)
        let report = await collector.collect([customer])

        #expect(!report.host.needsAttention)
        #expect(report.host.lines.contains { $0.text.contains("3 Notizen") })
        #expect(report.host.lines.contains { $0.text.hasPrefix("Token (lw-host): läuft ab am") && $0.text.contains("Stand") })
        #expect(report.host.lines.contains(.ok("Normale pass-cli-Anmeldung leer")))

        let section = try #require(report.customers.first)
        let todo = texts(section, .attention)
        let ok = texts(section, .ok)
        #expect(ok.contains(".envrc lädt lw env"))
        #expect(ok.contains { $0.hasPrefix("GitHub @loeti") })
        #expect(ok.contains { $0.hasPrefix("web: GitHub @loeti") })
        #expect(ok.contains("web: .envrc lädt lw env"))
        #expect(ok.contains("web: kundea-org/web, PAT deckt es ab"))

        // The customer's agent expires within warn_days (recorded date).
        #expect(todo.contains { $0.hasPrefix("Agent (asylum-kundea)") })
        // Repos without a project PAT, an outdated own .envrc, a repo the PAT doesn't cover.
        #expect(todo.contains { $0.hasPrefix("api: kein Projekt-PAT → lw init --project") })
        #expect(!todo.contains { $0.contains("kundea-org/api nicht ab") })
        #expect(todo.contains { $0.hasPrefix("legacy: kein Projekt-PAT") })
        #expect(todo.contains { $0.hasPrefix("legacy: eigene .envrc lädt lw env nicht") })
        #expect(todo.contains { $0.contains("deckt kundea-org/legacy nicht ab") })
        #expect(texts(section, .info).contains("notes: kein GitHub-origin"))
        #expect(!todo.contains { $0.hasPrefix("web:") })

        // Reading only: lists and views, nothing changed, all in the host's session.
        #expect(runner.mutations.isEmpty)
        #expect(runner.calls.allSatisfy { $0.sessionDirectory == "/s/host" && $0.environment["PROTON_PASS_AGENT_REASON"] != nil })

        let orphans = try #require(StatusCollector.orphans(root: tree.root))
        #expect(orphans.lines.map(\.text) == ["other/tool (loeti/tool): unter einen Kundenordner verschieben oder lw init"])
        #expect(orphans.needsAttention)
    }

    @Test("an unregistered config, a missing PAT note and a logged-in account are flagged")
    func problems() async throws {
        let tree = try makeTree()
        let runner = hostRunner()
        runner.on(["item", "list"], stdout: #"{"items": [{"id": "1", "share_id": "t", "title": "KundeA GitHub PAT"}]}"#)
        let (collector, customer) = try collector(tree, runner: runner, registered: false, checker: nil,
                                                  defaultSession: .account(username: "loeti"))
        let report = await collector.collect([customer])
        let todo = texts(try #require(report.customers.first), .attention)
        #expect(todo.contains { $0.contains("nicht registriert") && $0.contains("lw apply KundeA") })
        #expect(todo.contains { $0.hasPrefix("web: GitHub: Token fehlt") && $0.hasSuffix("lw github KundeA --project web") })
        #expect(report.host.lines.contains { $0.level == .attention && $0.text.contains("pass-cli logout") })
        // Offline: stored, but not checked.
        #expect(texts(try #require(report.customers.first), .ok).contains("GitHub: Token abgelegt (nicht geprüft)"))
    }

    @Test("a repo without any PAT is one line, with the repo and the fix")
    func noPAT() async throws {
        let tree = try makeTree()
        let file = tree.customer.appendingPathComponent(CustomerConfig.fileName)
        try Fixtures.write(Fixtures.kundeA.components(separatedBy: "\ngithub:")[0] + "\n", to: file)
        try FileManager.default.removeItem(at: tree.customer.appendingPathComponent("web/\(ProjectConfig.fileName)"))
        let (collector, customer) = try collector(tree, runner: hostRunner(), checker: checker)
        let report = await collector.collect([customer])
        let todo = texts(try #require(report.customers.first), .attention)
        let api = todo.filter { $0.hasPrefix("api:") }
        #expect(api.count == 1)
        #expect(api.first?.hasPrefix("api: kundea-org/api ohne PAT → lw init --project /") == true)
        #expect(api.first?.hasSuffix("/api") == true)
        // Without an origin there is no repo name, so the project line stays.
        #expect(todo.contains { $0.hasPrefix("notes: kein Projekt-PAT → lw init --project") })
    }

    @Test("without a host agent nothing is read, and that is the first thing to fix")
    func noHost() async throws {
        let tree = try makeTree()
        var (collector, customer) = try collector(tree, runner: FakeRunner(), checker: checker)
        collector.host = .failure(LWError("host-token fehlt"))
        let report = await collector.collect([customer])
        #expect(report.host.lines.contains(.todo("host-token fehlt")))
        #expect(texts(try #require(report.customers.first), .info).contains { $0.contains("nicht prüfbar") })
    }

    @Test("with the account: grants of the customer's and the host agent")
    func withAccount() async throws {
        let tree = try makeTree()
        let runner = hostRunner()
        runner.on(["pat", "access", "list-access", "--personal-access-token-id", "p1"], stdout: """
        [{"type": "vault", "share_id": "s1", "role": "Viewer", "vault_name": "agent-kundea"},
         {"type": "vault", "share_id": "s2", "role": "Editor", "vault_name": "agent-kundea-infra"}]
        """)
        runner.on(["pat", "access", "list-access", "--personal-access-token-id", "h1"], stdout: """
        [{"type": "vault", "share_id": "s3", "role": "Viewer", "vault_name": "lw-tokens"},
         {"type": "vault", "share_id": "s4", "role": "Viewer", "vault_name": "agent-kundea"}]
        """)
        var (collector, customer) = try collector(tree, runner: runner, checker: nil)
        collector.account = PassCLI(runner: runner, sessionDirectory: URL(fileURLWithPath: "/s/account"))
        collector.agents = [ProtonAgent(id: "p1", name: "asylum-kundea", expires: days(90)),
                            ProtonAgent(id: "h1", name: "lw-host", expires: days(90))]
        let report = await collector.collect([customer])

        let section = try #require(report.customers.first)
        #expect(texts(section, .ok).contains("Rechte wie konfiguriert"))
        #expect(texts(section, .ok).contains { $0.hasPrefix("Agent asylum-kundea: läuft ab") && !$0.contains("Stand") })
        // The host agent may only read the token vault.
        #expect(report.host.lines.contains(.todo("Rechte weichen ab → lw host --setup")))
        #expect(report.host.lines.contains(.info("- Vault 'agent-kundea' (viewer) entziehen")))
        #expect(runner.mutations.isEmpty)
    }

    @Test("GitHub remotes in their usual spellings")
    func remotes() {
        for url in ["git@github.com:o/r.git", "git@github.com:o/r", "ssh://git@github.com/o/r.git", "https://github.com/o/r",
                    "https://github.com/o/r.git/", "https://user@github.com/o/r.git"] {
            #expect(GitHubRepository(remote: url) == GitHubRepository(owner: "o", name: "r"), "\(url)")
        }
        for url in ["git@gitlab.com:o/r.git", "https://bitbucket.org/o/r", "https://github.com/o", "/local/path"] {
            #expect(GitHubRepository(remote: url) == nil, "\(url)")
        }
    }

    @Test("origin comes from .git/config, also for a worktree")
    func origin() throws {
        let base = try Fixtures.temporaryDirectory()
        try Self.repo(base.appendingPathComponent("main"), origin: "git@github.com:o/r.git")
        #expect(GitRepository.open(base.appendingPathComponent("main"))?.github == GitHubRepository(owner: "o", name: "r"))

        let worktreeGitDir = base.appendingPathComponent("main/.git/worktrees/feature")
        try Fixtures.write("../..\n", to: worktreeGitDir.appendingPathComponent("commondir"))
        try Fixtures.write("gitdir: \(worktreeGitDir.path)\n", to: base.appendingPathComponent("feature/.git"))
        #expect(GitRepository.open(base.appendingPathComponent("feature"))?.github == GitHubRepository(owner: "o", name: "r"))

        #expect(GitRepository.originURL(inConfig: "[remote \"upstream\"]\n\turl = x\n[remote \"origin\"]\n\turl = y\n") == "y")
        #expect(GitRepository.open(base.appendingPathComponent("none")) == nil)
    }

    @Test("expiry dates survive a round trip")
    func expiries() throws {
        let file = try Fixtures.temporaryDirectory().appendingPathComponent("agents.yaml")
        var expiries = AgentExpiries()
        expiries.record([ProtonAgent(id: "1", name: "lw-host", expires: days(30)), ProtonAgent(id: "2", name: "x", expires: nil)], now: now)
        try expiries.save(file)
        #expect(AgentExpiries.load(file) == expiries)
        #expect(AgentExpiries.load(file.deletingLastPathComponent().appendingPathComponent("missing")) == AgentExpiries())
    }
}
