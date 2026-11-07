import Foundation
import Testing
@testable import LoetiWayKit

@Suite("lw env, host agent and sessions")
struct EnvTests {
    static let hostInfo = "- Release track: stable\n- Personal Access Token: lw-host\n"
    static let agentInfo = "- Release track: stable\n- Personal Access Token: agent-kundea\n"
    static let accountInfo = "- Release track: stable\n- ID: u1\n- Username: loeti\n"

    static let customerYAML = Fixtures.kundeAWithWeb + """

    env:
      MAVEN_PASSWORD: pass://agent-kundea/Maven/password
    """

    /// The registry with KundeA and its projects as they are on disk.
    func registry(_ customer: URL) throws -> CustomerRegistry {
        var registry = CustomerRegistry()
        try registry.register(CustomerLocator.load(file: customer.appendingPathComponent(CustomerConfig.fileName)))
        return registry
    }

    /// root/customers/KundeA with env, project web (own vault and token) and broken (invalid project file).
    func makeTree() throws -> (root: URL, customer: URL, global: GlobalConfig) {
        let root = try Fixtures.temporaryDirectory()
        let customer = root.appendingPathComponent("customers/KundeA")
        try Fixtures.write(Self.customerYAML, to: customer.appendingPathComponent(CustomerConfig.fileName))
        try Fixtures.write("vault: own\ntokens:\n  github: {}\n", to: customer.appendingPathComponent("web/\(ProjectConfig.fileName)"))
        try Fixtures.write("tokens: [", to: customer.appendingPathComponent("broken/\(ProjectConfig.fileName)"))
        for folder in ["web/src", "broken/src", "other"] {
            try FileManager.default.createDirectory(at: customer.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let global = GlobalConfig(root: root, hostAgent: "lw-host", environment: ["HOME": root.path])
        return (root, customer, global)
    }

    /// `info` answers per session: lw-host in host, agent-kundea in agent-kundea.
    func runnerWithTokens() -> FakeRunner {
        let runner = FakeRunner()
        runner.on(["info"], stdout: Self.hostInfo)
        runner.onSession("agent-kundea", ["info"], stdout: Self.agentInfo)
        runner.on(["item", "view", "pass://agent-kundea/GitHub Token/note"], stdout: "github_pat_customer\n")
        runner.on(["item", "view", "pass://agent-kundea-web/GitHub Token/note"], stdout: "github_pat_web\n")
        runner.on(["item", "view", "pass://lw-tokens/KundeA Proton Agent/note"], stdout: "pst_agent::key\n")
        runner.on(["item", "view", "pass://agent-kundea/Maven/password"], stdout: "s3cr'et\n")
        return runner
    }

    func value(_ export: EnvExport, _ name: String) -> EnvExport.Value? {
        export.variables.first { $0.name == name }?.value
    }

    func build(_ tree: (root: URL, customer: URL, global: GlobalConfig), _ path: String, runner: FakeRunner,
               registry: CustomerRegistry? = nil, hostToken: () throws -> String = { "pst_host::key" }) throws -> (EnvExport, SessionStore) {
        let sessions = SessionStore(base: tree.global.sessionsDirectory, runner: runner)
        let export = EnvExport.build(directory: tree.customer.appendingPathComponent(path), global: tree.global,
                                     registry: try registry ?? self.registry(tree.customer), sessions: sessions, hostToken: hostToken)
        return (export, sessions)
    }

    @Test("in a project: its token and the customer's env values, all read by the customer's agent")
    func project() throws {
        let tree = try makeTree()
        let runner = runnerWithTokens()
        let (export, sessions) = try build(tree, "web/src", runner: runner)

        #expect(export.warnings == [])
        #expect(value(export, "LW_ENV_GH_TOKEN") == .set("github_pat_web"))
        #expect(value(export, "LW_ENV_MAVEN_PASSWORD") == .set("s3cr'et"))
        #expect(export.shell.contains("export LW_ENV_MAVEN_PASSWORD='s3cr'\\''et'"))
        #expect(!export.summary.contains("s3cr") && !export.summary.contains("github_pat"))
        #expect(export.summary.contains("export LW_ENV_GH_TOKEN=…"))

        let views = runner.calls.filter { $0.arguments.starts(with: ["item", "view"]) }
        let agent = sessions.directory("agent-kundea").path
        // The customer's agent is still logged in: the host agent isn't needed at all.
        #expect(views.allSatisfy { $0.sessionDirectory == agent })
        #expect(Set(views.map { $0.arguments[2] }) == ["pass://agent-kundea-web/GitHub Token/note", "pass://agent-kundea/Maven/password"])
        #expect(!runner.calls.contains { $0.sessionDirectory == sessions.directory(SessionStore.host).path })
        // Agents must give a reason, and every call names its session: never the default one.
        #expect(views.allSatisfy { $0.environment["PROTON_PASS_AGENT_REASON"]?.isEmpty == false })
        #expect(runner.calls.allSatisfy { $0.sessionDirectory != nil })
        #expect(!runner.calls.contains { $0.arguments == ["login"] })
    }

    @Test("outside a project the customer's token applies")
    func customerFolder() throws {
        let (export, _) = try build(try makeTree(), "other", runner: runnerWithTokens())
        #expect(value(export, "LW_ENV_GH_TOKEN") == .set("github_pat_customer"))
    }

    @Test("inside a broken project everything is unset, never the customer's token")
    func brokenProject() throws {
        let runner = runnerWithTokens()
        let (export, _) = try build(try makeTree(), "broken/src", runner: runner)
        #expect(value(export, "LW_ENV_GH_TOKEN") == .unset)
        #expect(value(export, "LW_ENV_MAVEN_PASSWORD") == .unset)
        #expect(export.warnings.contains { $0.contains("broken") })
        #expect(!runner.calls.contains { $0.arguments.starts(with: ["item", "view"]) })
        #expect(export.shell.contains("unset LW_ENV_GH_TOKEN"))
    }

    @Test("an unregistered or changed project gets nothing, the rest of the customer still works")
    func unregisteredProject() throws {
        let tree = try makeTree()
        let registered = try registry(tree.customer)
        // An agent points the project at another vault's item.
        try Fixtures.write("vault: own\ntokens:\n  github: {}\nenv:\n  X: pass://agent-kundea-infra/Deploy/password\n",
                           to: tree.customer.appendingPathComponent("web/\(ProjectConfig.fileName)"))
        let runner = runnerWithTokens()
        var (export, _) = try build(tree, "web/src", runner: runner, registry: registered)
        #expect(value(export, "LW_ENV_GH_TOKEN") == .unset)
        #expect(value(export, "LW_ENV_X") == .unset)
        #expect(export.warnings.contains { $0.contains("weicht von der Registrierung ab") })
        #expect(!runner.calls.contains { $0.arguments.starts(with: ["item", "view"]) })

        (export, _) = try build(tree, "other", runner: runner, registry: registered)
        #expect(value(export, "LW_ENV_GH_TOKEN") == .set("github_pat_customer"))
        let changed = try CustomerLocator.load(file: tree.customer.appendingPathComponent(CustomerConfig.fileName))
        #expect(registered.changes(for: changed).contains { $0.contains("X: – → pass://agent-kundea-infra/Deploy/password") })
    }

    @Test("a logged-out customer agent logs in with its token, read by the host agent with host-token")
    func agentLogin() throws {
        let tree = try makeTree()
        let runner = runnerWithTokens()
        runner.once(["info"], status: 1, stderr: "This operation requires an authenticated client")  // agent: not yet
        runner.once(["info"], status: 1, stderr: "This operation requires an authenticated client")  // host: not yet
        let (export, sessions) = try build(tree, "other", runner: runner)

        #expect(value(export, "LW_ENV_MAVEN_PASSWORD") == .set("s3cr'et"))
        let logins = runner.calls.filter { $0.arguments == ["login"] }
        #expect(logins.map(\.sessionDirectory) == [sessions.directory(SessionStore.host).path, sessions.directory("agent-kundea").path])
        #expect(logins.map { $0.environment["PROTON_PASS_PERSONAL_ACCESS_TOKEN"] } == ["pst_host::key", "pst_agent::key"])
        let read = try #require(runner.calls.first { $0.arguments.contains("pass://lw-tokens/KundeA Proton Agent/note") })
        #expect(read.sessionDirectory == sessions.directory(SessionStore.host).path)
    }

    @Test("without a usable host agent everything is unset, with a hint")
    func noHost() throws {
        let runner = runnerWithTokens()
        runner.on(["info"], status: 1)
        runner.onSession("agent-kundea", ["info"], status: 1)
        let (export, _) = try build(try makeTree(), "web", runner: runner) { throw LWError("host-token fehlt") }
        #expect(value(export, "LW_ENV_GH_TOKEN") == .unset)
        #expect(value(export, "LW_ENV_MAVEN_PASSWORD") == .unset)
        #expect(export.warnings.contains { $0.contains("Host-Agent: host-token fehlt") })
        #expect(!runner.calls.contains { $0.arguments.starts(with: ["item", "view"]) })
    }

    @Test("an unregistered or changed customer config gets nothing: an agent may have written it")
    func registryGate() throws {
        let tree = try makeTree()
        let runner = runnerWithTokens()
        var (export, _) = try build(tree, "web", runner: runner, registry: CustomerRegistry())
        #expect(value(export, "LW_ENV_GH_TOKEN") == .unset)
        #expect(export.warnings.contains { $0.contains("nicht registriert") })

        let registered = try registry(tree.customer)
        let file = tree.customer.appendingPathComponent(CustomerConfig.fileName)
        try Fixtures.write(Self.customerYAML.replacingOccurrences(of: "  expiration: 1m\n", with: "  expiration: 1m\n  token_item: KundeB Proton Agent\n"), to: file)
        (export, _) = try build(tree, "web", runner: runner, registry: registered)
        #expect(value(export, "LW_ENV_GH_TOKEN") == .unset)
        #expect(export.warnings.contains { $0.contains("weicht von der Registrierung ab") })
        #expect(!runner.calls.contains { $0.arguments.starts(with: ["item", "view"]) })

        // Redirecting an env value needs a new confirmation as well.
        try Fixtures.write(Self.customerYAML.replacingOccurrences(of: "agent-kundea/Maven", with: "agent-kundea-infra/Deploy"), to: file)
        let changed = try CustomerLocator.load(file: file)
        #expect(throws: LWError.self) { try registered.verify(changed) }
        #expect(registered.changes(for: changed).contains { $0.hasPrefix("MAVEN_PASSWORD") })
    }

    @Test("a session that doesn't name its agent is refused")
    func unnamedAgent() throws {
        #expect(throws: LWError.self) { try SessionStore.check(nil, expected: "lw-host") }
        #expect(throws: LWError.self) { try SessionStore.check("agent-kundea", expected: "lw-host") }
        try SessionStore.check("lw-host", expected: "lw-host")
    }

    @Test("a session of another agent is refused before anything is read")
    func wrongAgent() throws {
        let runner = runnerWithTokens()
        runner.onSession("agent-kundea", ["info"], stdout: "- Personal Access Token: agent-kundeb\n")
        let (export, _) = try build(try makeTree(), "other", runner: runner)
        #expect(value(export, "LW_ENV_MAVEN_PASSWORD") == .unset)
        #expect(export.warnings.contains { $0.contains("agent-kundeb") })
        #expect(!runner.calls.contains { $0.arguments.contains("pass://agent-kundea/Maven/password") })
    }

    @Test("the registry refuses a second customer with the same agent, note or vault")
    func registryConflicts() throws {
        let (_, customer, _) = try makeTree()
        var registry = try registry(customer)
        let other = try Fixtures.temporaryDirectory().appendingPathComponent("KundeA-copy")
        try Fixtures.write(Self.customerYAML, to: other.appendingPathComponent(CustomerConfig.fileName))
        #expect(throws: LWError.self) { try registry.register(CustomerLocator.load(file: other.appendingPathComponent(CustomerConfig.fileName))) }
        #expect(registry.changes(for: try CustomerLocator.load(file: customer.appendingPathComponent(CustomerConfig.fileName))).isEmpty)

        // Another customer granted KundeA's token vault: its tokens would be readable there.
        let thief = Fixtures.temporaryDirectory
        let kundeB = try thief().appendingPathComponent("KundeB")
        try Fixtures.write("customer: KundeB\nproton:\n  vaults: [{name: agent-kundeb}, {name: agent-kundea}]\n", to: kundeB.appendingPathComponent(CustomerConfig.fileName))
        #expect(throws: LWError.self) { try registry.register(CustomerLocator.load(file: kundeB.appendingPathComponent(CustomerConfig.fileName))) }

        let file = try Fixtures.temporaryDirectory().appendingPathComponent("customers.yaml")
        try registry.save(file)
        #expect(try CustomerRegistry.load(file) == registry)
        #expect(registry.entries.first?.projects.count == 1)
    }

    @Test("a missing token only unsets its own variable, with where it belongs")
    func missingNote() throws {
        let runner = runnerWithTokens()
        runner.on(["item", "view", "pass://agent-kundea-web/GitHub Token/note"], status: 1, stderr: "Item not found")
        let (export, _) = try build(try makeTree(), "web", runner: runner)
        #expect(value(export, "LW_ENV_GH_TOKEN") == .unset)
        #expect(value(export, "LW_ENV_MAVEN_PASSWORD") == .set("s3cr'et"))
        #expect(export.warnings.contains { $0.contains("lw token github KundeA --project web") && $0.contains("'GitHub Token' in 'agent-kundea-web'") })
    }

    @Test("env names and references are checked")
    func envValidation() throws {
        func validate(_ env: String) throws {
            try CustomerConfig.parse(Fixtures.kundeA + "\nenv:\n" + env).validate(tokenVault: "lw-tokens")
        }
        try validate("  MAVEN_PASSWORD: pass://agent-kundea-infra/Maven/password\n")
        for bad in [
            "  maven: pass://agent-kundea/Maven/password",          // lowercase
            "  PATH: pass://agent-kundea/Maven/password",           // reserved
            "  PROTON_PASS_X: pass://agent-kundea/Maven/password",  // pass-cli's own
            "  GH_TOKEN: pass://agent-kundea/Maven/password",       // the GitHub token's variable
            "  X: pass://agent-kundea/Maven",                       // no field
            "  X: pass://agent-other/Maven/password",               // not granted
            "  X: pass://lw-tokens/KundeA Proton Agent/note",       // token vault
            "  X: https://example.com",
        ] {
            #expect(throws: LWError.self, "\(bad)") { try validate(bad) }
        }
    }

    @Test("host-token is written 0600 and refused when others can read it")
    func hostToken() throws {
        let file = try Fixtures.temporaryDirectory().appendingPathComponent("loeti-way/host-token")
        try HostToken.write("PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_abc::key", to: file)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try HostToken.read(file) == "pst_abc::key")

        try HostToken.write("pst_new::key", to: file)
        #expect(try HostToken.read(file) == "pst_new::key")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: LWError.self) { try HostToken.read(file) }
        #expect(throws: LWError.self) { try HostToken.write("github_pat_x", to: file) }
        #expect(throws: LWError.self) { try HostToken.read(file.deletingLastPathComponent().appendingPathComponent("missing")) }
    }

    @Test("the account session exists only while the command runs, also when it fails")
    func accountSession() async throws {
        let base = try Fixtures.temporaryDirectory()
        let runner = FakeRunner()
        runner.on(["info"], stdout: Self.accountInfo)
        let sessions = SessionStore(base: base, runner: runner)
        let directory = sessions.directory(SessionStore.account)

        let seen = try await sessions.withAccount { pass in
            #expect(FileManager.default.fileExists(atPath: directory.path))
            return pass.sessionDirectory
        }
        #expect(seen == directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(runner.calls.contains { $0.arguments == ["login"] && $0.sessionDirectory == directory.path })
        #expect(runner.calls.last?.arguments.first == "logout")

        // A token where the account is expected: refused, and still cleaned up.
        runner.on(["info"], stdout: Self.hostInfo)
        await #expect(throws: LWError.self) { try await sessions.withAccount { _ in () } }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
