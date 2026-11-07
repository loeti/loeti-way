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
    /// - web: repo, project with own vault and GitHub token, and .envrc
    /// - api: repo without project, covered by the customer's token
    /// - legacy: repo without project, own outdated .envrc, not covered
    /// - notes: repo without origin
    /// and root/other/tool, a repo outside every customer.
    func makeTree() throws -> (root: URL, customer: URL, global: GlobalConfig) {
        let root = try Fixtures.temporaryDirectory()
        let customer = root.appendingPathComponent("customers/KundeA")
        try Fixtures.write(Fixtures.kundeAWithWeb + "\nenv:\n  MAVEN_PASSWORD: pass://agent-kundea/Maven/password\n",
                           to: customer.appendingPathComponent(CustomerConfig.fileName))
        try Fixtures.write(Scaffold.envrc, to: customer.appendingPathComponent(".envrc"))

        try Self.repo(customer.appendingPathComponent("web"), origin: "git@github.com:kundea-org/web.git")
        try Fixtures.write("vault: own\ntokens:\n  github: {}\n", to: customer.appendingPathComponent("web/\(ProjectConfig.fileName)"))
        try Fixtures.write(Scaffold.envrc, to: customer.appendingPathComponent("web/.envrc"))

        try Self.repo(customer.appendingPathComponent("api"), origin: "https://github.com/kundea-org/api")
        try Self.repo(customer.appendingPathComponent("legacy"), origin: "ssh://git@github.com/kundea-org/legacy.git")
        try Fixtures.write("export ASYLUM_GH_TOKEN=\"$(pass-cli item view \"pass://lw-tokens/x/note\")\"\n", to: customer.appendingPathComponent("legacy/.envrc"))
        try Self.repo(customer.appendingPathComponent("notes"), origin: nil)

        try Self.repo(root.appendingPathComponent("other/tool"), origin: "git@github.com:loeti/tool.git")
        return (root, customer, GlobalConfig(root: root, environment: ["HOME": root.path]))
    }

    /// Host session: the token vault. Agent session: the customer's and the project's vault.
    func runner() -> FakeRunner {
        let runner = FakeRunner()
        runner.on(["item", "list", "--vault-name", "lw-tokens"], stdout: #"{"items": [{"id": "1", "share_id": "t", "title": "KundeA Proton Agent"}]}"#)
        runner.on(["item", "list", "--vault-name", "agent-kundea"], stdout: """
        {"items": [{"id": "2", "share_id": "a", "title": "GitHub Token"}, {"id": "3", "share_id": "a", "title": "Maven"}]}
        """)
        runner.on(["item", "list", "--vault-name", "agent-kundea-web"], stdout: #"{"items": [{"id": "4", "share_id": "w", "title": "GitHub Token"}]}"#)
        runner.on(["item", "view", "pass://agent-kundea/GitHub Token/note"], stdout: "github_pat_customer\n")
        runner.on(["item", "view", "pass://agent-kundea-web/GitHub Token/note"], stdout: "github_pat_web\n")
        return runner
    }

    func collector(_ tree: (root: URL, customer: URL, global: GlobalConfig), runner: FakeRunner, registered: Bool = true,
                   checker: (any GitHubTokenChecker)?, defaultSession: PassSession = .loggedOut,
                   agentLogin: ((CustomerConfig) throws -> PassCLI)? = nil) throws -> (StatusCollector, LoadedCustomer) {
        let customer = try CustomerLocator.load(file: tree.customer.appendingPathComponent(CustomerConfig.fileName))
        var registry = CustomerRegistry()
        if registered { try registry.register(customer) }
        let collector = StatusCollector(
            global: tree.global,
            registry: registry,
            expiries: AgentExpiries(expires: ["agent-kundea": days(5), "lw-host": days(60)], checked: days(-1)),
            host: .success(PassCLI(runner: runner, sessionDirectory: URL(fileURLWithPath: "/s/host"))),
            defaultSession: defaultSession,
            checker: checker,
            agentLogin: agentLogin ?? { _ in PassCLI(runner: runner, sessionDirectory: URL(fileURLWithPath: "/s/agent")) },
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

    @Test("without the account: agent tokens, provider tokens, env, .envrc and every repository")
    func overview() async throws {
        let tree = try makeTree()
        let runner = runner()
        let (collector, customer) = try collector(tree, runner: runner, checker: checker)
        let report = await collector.collect([customer])

        #expect(!report.host.needsAttention)
        #expect(report.host.lines.contains { $0.text.contains("1 Notizen") })
        #expect(report.host.lines.contains { $0.text.hasPrefix("Token (lw-host): läuft ab am") && $0.text.contains("Stand") })
        #expect(report.host.lines.contains(.ok("Normale pass-cli-Anmeldung leer")))

        let section = try #require(report.customers.first)
        let todo = texts(section, .attention)
        let ok = texts(section, .ok)
        #expect(ok.contains(".envrc lädt lw env"))
        #expect(ok.contains { $0.hasPrefix("GitHub @loeti") })
        #expect(ok.contains("env: MAVEN_PASSWORD"))
        #expect(ok.contains { $0.hasPrefix("web: GitHub @loeti") })
        #expect(ok.contains("web: .envrc lädt lw env"))
        #expect(ok.contains("web: kundea-org/web, Token deckt es ab"))

        // The customer's agent expires within warn_days (recorded date).
        #expect(todo.contains { $0.hasPrefix("Agent (agent-kundea)") })
        // api is covered by the customer's token: nothing to say.
        #expect(!todo.contains { $0.hasPrefix("api:") })
        #expect(todo.contains { $0.hasPrefix("legacy: eigene .envrc lädt lw env nicht") })
        #expect(todo.contains { $0.contains("'KundeA_PAT' (KundeA) deckt kundea-org/legacy nicht ab") })
        #expect(texts(section, .info).contains("notes: kein GitHub-origin"))
        #expect(!todo.contains { $0.hasPrefix("web:") })

        // Reading only: lists and views, nothing changed. Agent tokens with the host, the rest with the agent.
        #expect(runner.mutations.isEmpty)
        #expect(runner.calls.allSatisfy { $0.environment["PROTON_PASS_AGENT_REASON"] != nil })
        #expect(runner.calls.filter { $0.sessionDirectory == "/s/host" }.allSatisfy { $0.arguments.contains("lw-tokens") })

        let orphans = try #require(StatusCollector.orphans(root: tree.root))
        #expect(orphans.lines.map(\.text) == ["other/tool (loeti/tool): unter einen Kundenordner verschieben oder lw init"])
        #expect(orphans.needsAttention)
    }

    @Test("an unregistered config is flagged and nothing it names is read")
    func unregistered() async throws {
        let tree = try makeTree()
        let runner = runner()
        var logins = 0
        let (collector, customer) = try collector(tree, runner: runner, registered: false, checker: checker) { _ in
            logins += 1
            return PassCLI(runner: runner, sessionDirectory: URL(fileURLWithPath: "/s/agent"))
        }
        let report = await collector.collect([customer])
        let section = try #require(report.customers.first)
        #expect(texts(section, .attention).contains { $0.contains("nicht registriert") && $0.contains("lw apply KundeA") })
        #expect(texts(section, .info).contains { $0.hasPrefix("Tokens, env und Repos nicht geprüft") })
        #expect(!section.lines.contains { $0.text.contains("GitHub @") || $0.text.hasPrefix("web:") || $0.text.hasPrefix("api:") })
        #expect(logins == 0)
        #expect(!runner.calls.contains { $0.arguments.starts(with: ["item", "view"]) })
    }

    @Test("an unregistered project is flagged and not read; the customer is")
    func unregisteredProject() async throws {
        let tree = try makeTree()
        let runner = runner()
        var (collector, customer) = try collector(tree, runner: runner, checker: checker)
        collector.registry.entries[0].projects = [:]
        let report = await collector.collect([customer])
        let section = try #require(report.customers.first)
        #expect(texts(section, .attention).contains { $0.hasPrefix("web: ") && $0.contains("nicht registriert") })
        #expect(texts(section, .ok).contains { $0.hasPrefix("GitHub @loeti") })
        #expect(!runner.calls.contains { $0.arguments.contains("pass://agent-kundea-web/GitHub Token/note") })
        #expect(!section.lines.contains { $0.text.hasPrefix("web: kundea-org") })
    }

    @Test("missing tokens and items are flagged with where they belong; a logged-in account too")
    func problems() async throws {
        let tree = try makeTree()
        let runner = runner()
        runner.on(["item", "list", "--vault-name", "agent-kundea-web"], stdout: #"{"items": []}"#)
        runner.on(["item", "list", "--vault-name", "agent-kundea"], stdout: #"{"items": [{"id": "2", "share_id": "a", "title": "GitHub Token"}]}"#)
        runner.on(["item", "list", "--vault-name", "lw-tokens"], stdout: #"{"items": []}"#)
        let (collector, customer) = try collector(tree, runner: runner, checker: nil, defaultSession: .account(username: "loeti"))
        let report = await collector.collect([customer])
        let section = try #require(report.customers.first)
        let todo = texts(section, .attention)
        #expect(todo.contains("web: GitHub: Token fehlt in 'agent-kundea-web' / 'GitHub Token' → lw token github KundeA --project web"))
        #expect(todo.contains("env MAVEN_PASSWORD: Eintrag 'Maven' fehlt in 'agent-kundea'"))
        #expect(todo.contains { $0.hasPrefix("Token des Agents fehlt in 'lw-tokens'") })
        #expect(report.host.lines.contains { $0.level == .attention && $0.text.contains("pass-cli logout") })
        // Offline: stored, but not checked.
        #expect(texts(section, .ok).contains("GitHub: Token abgelegt (nicht geprüft)"))
    }

    @Test("a GitHub repo without any GitHub token is one line, with the repo and the fix")
    func noToken() async throws {
        let tree = try makeTree()
        try Fixtures.write("customer: KundeA\nproton:\n  vaults: [{name: agent-kundea}]\n", to: tree.customer.appendingPathComponent(CustomerConfig.fileName))
        try FileManager.default.removeItem(at: tree.customer.appendingPathComponent("web/\(ProjectConfig.fileName)"))
        let (collector, customer) = try collector(tree, runner: runner(), checker: checker)
        let report = await collector.collect([customer])
        let todo = texts(try #require(report.customers.first), .attention)
        let api = todo.filter { $0.hasPrefix("api:") }
        #expect(api.count == 1)
        #expect(api.first?.hasPrefix("api: kundea-org/api ohne GitHub-Token → 'tokens.github' in .loeti-way.yaml oder lw init --project /") == true)
    }

    @Test("without a host agent the customer's agent can't log in, and that is reported")
    func noHost() async throws {
        let tree = try makeTree()
        var (collector, customer) = try collector(tree, runner: FakeRunner(), checker: checker) { _ in
            throw LWError("Host-Agent: host-token fehlt → lw host")
        }
        collector.host = .failure(LWError("host-token fehlt"))
        let report = await collector.collect([customer])
        #expect(report.host.lines.contains(.todo("host-token fehlt")))
        let section = try #require(report.customers.first)
        #expect(texts(section, .attention).contains { $0.hasPrefix("Agent-Anmeldung: Host-Agent: host-token fehlt") })
        #expect(texts(section, .info).contains("Tokens und env nicht prüfbar"))
    }

    @Test("with the account: grants of the customer's and the host agent")
    func withAccount() async throws {
        let tree = try makeTree()
        let runner = runner()
        runner.on(["pat", "access", "list-access", "--personal-access-token-id", "p1"], stdout: """
        [{"type": "vault", "share_id": "s1", "role": "Viewer", "vault_name": "agent-kundea"},
         {"type": "vault", "share_id": "s2", "role": "Editor", "vault_name": "agent-kundea-infra"},
         {"type": "vault", "share_id": "s5", "role": "Viewer", "vault_name": "agent-kundea-web"}]
        """)
        runner.on(["pat", "access", "list-access", "--personal-access-token-id", "h1"], stdout: """
        [{"type": "vault", "share_id": "s3", "role": "Viewer", "vault_name": "lw-tokens"},
         {"type": "vault", "share_id": "s4", "role": "Viewer", "vault_name": "agent-kundea"}]
        """)
        var (collector, customer) = try collector(tree, runner: runner, checker: nil)
        collector.account = PassCLI(runner: runner, sessionDirectory: URL(fileURLWithPath: "/s/account"))
        collector.agents = [ProtonAgent(id: "p1", name: "agent-kundea", expires: days(90)),
                            ProtonAgent(id: "h1", name: "lw-host", expires: days(90))]
        let report = await collector.collect([customer])

        let section = try #require(report.customers.first)
        #expect(texts(section, .ok).contains("Rechte wie konfiguriert"))
        #expect(texts(section, .ok).contains { $0.hasPrefix("Agent agent-kundea: läuft ab") && !$0.contains("Stand") })
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
