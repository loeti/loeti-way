import Foundation
import Testing
@testable import LoetiWayKit

@Suite("lw env, host agent and sessions")
struct EnvTests {
    static let hostInfo = "- Release track: stable\n- Personal Access Token: lw-host\n"
    static let accountInfo = "- Release track: stable\n- ID: u1\n- Username: loeti\n"

    static let customerYAML = Fixtures.kundeA + """

    env:
      MAVEN_PASSWORD: pass://agent-kundea/Maven/password
    """

    /// root/customers/KundeA with env, project web (own PAT) and broken (invalid project file).
    func makeTree() throws -> (root: URL, customer: URL, global: GlobalConfig) {
        let root = try Fixtures.temporaryDirectory()
        let customer = root.appendingPathComponent("customers/KundeA")
        try Fixtures.write(Self.customerYAML, to: customer.appendingPathComponent(CustomerConfig.fileName))
        try Fixtures.write("{}\n", to: customer.appendingPathComponent("web/\(ProjectConfig.fileName)"))
        try Fixtures.write("github: [", to: customer.appendingPathComponent("broken/\(ProjectConfig.fileName)"))
        for folder in ["web/src", "broken/src", "other"] {
            try FileManager.default.createDirectory(at: customer.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let global = GlobalConfig(root: root, environment: ["HOME": root.path])
        return (root, customer, global)
    }

    func runnerWithTokens() -> FakeRunner {
        let runner = FakeRunner()
        runner.on(["info"], stdout: Self.hostInfo)
        runner.on(["item", "view", "pass://lw-tokens/KundeA GitHub PAT/note"], stdout: "github_pat_customer\n")
        runner.on(["item", "view", "pass://lw-tokens/KundeA web GitHub PAT/note"], stdout: "github_pat_web\n")
        runner.on(["item", "view", "pass://lw-tokens/KundeA Proton Agent/note"], stdout: "pst_agent::key\n")
        runner.on(["item", "view", "pass://agent-kundea/Maven/password"], stdout: "s3cr'et\n")
        return runner
    }

    func value(_ export: EnvExport, _ name: String) -> EnvExport.Value? {
        export.variables.first { $0.name == name }?.value
    }

    @Test("in a project: its PAT and the env values; host reads tokens, the customer's agent the values")
    func project() throws {
        let (_, customer, global) = try makeTree()
        let runner = runnerWithTokens()
        let sessions = SessionStore(base: global.sessionsDirectory, runner: runner)
        let export = EnvExport.build(directory: customer.appendingPathComponent("web/src"), global: global, sessions: sessions) { "pst_host::key" }

        #expect(export.warnings == [])
        #expect(value(export, "ASYLUM_GH_TOKEN") == .set("github_pat_web"))
        #expect(value(export, "MAVEN_PASSWORD") == .set("s3cr'et"))
        #expect(export.shell.contains("export MAVEN_PASSWORD='s3cr'\\''et'"))

        let views = runner.calls.filter { $0.arguments.starts(with: ["item", "view"]) }
        let host = sessions.directory(SessionStore.host).path
        let agent = sessions.directory("agent-kundea").path
        // The customer's agent is still logged in, so its token isn't even read.
        #expect(views.filter { $0.sessionDirectory == host }.map { $0.arguments[2] } == ["pass://lw-tokens/KundeA web GitHub PAT/note"])
        #expect(views.filter { $0.sessionDirectory == agent }.map { $0.arguments[2] } == ["pass://agent-kundea/Maven/password"])
        // Agents must give a reason, and every call names its session: never the default one.
        #expect(views.allSatisfy { $0.environment["PROTON_PASS_AGENT_REASON"]?.isEmpty == false })
        #expect(runner.calls.allSatisfy { $0.sessionDirectory != nil })
        #expect(!runner.calls.contains { $0.arguments == ["login"] })
    }

    @Test("outside a project the customer's PAT applies")
    func customerFolder() throws {
        let (_, customer, global) = try makeTree()
        let export = EnvExport.build(directory: customer.appendingPathComponent("other"), global: global,
                                     sessions: SessionStore(base: global.sessionsDirectory, runner: runnerWithTokens())) { "pst_host::key" }
        #expect(value(export, "ASYLUM_GH_TOKEN") == .set("github_pat_customer"))
    }

    @Test("inside a broken project the GitHub variable is unset, never the customer's PAT")
    func brokenProject() throws {
        let (_, customer, global) = try makeTree()
        let runner = runnerWithTokens()
        let export = EnvExport.build(directory: customer.appendingPathComponent("broken/src"), global: global,
                                     sessions: SessionStore(base: global.sessionsDirectory, runner: runner)) { "pst_host::key" }
        #expect(value(export, "ASYLUM_GH_TOKEN") == .unset)
        #expect(export.warnings.contains { $0.contains("GitHub-PAT") })
        #expect(!runner.calls.contains { $0.arguments.contains("pass://lw-tokens/KundeA GitHub PAT/note") })
        #expect(export.shell.contains("unset ASYLUM_GH_TOKEN"))
    }

    @Test("a logged-out host agent logs in with host-token, through the environment")
    func hostLogin() throws {
        let (_, customer, global) = try makeTree()
        let runner = runnerWithTokens()
        runner.once(["info"], status: 1, stderr: "This operation requires an authenticated client")
        let sessions = SessionStore(base: global.sessionsDirectory, runner: runner)
        let export = EnvExport.build(directory: customer.appendingPathComponent("other"), global: global, sessions: sessions) { "pst_host::key" }

        #expect(value(export, "ASYLUM_GH_TOKEN") == .set("github_pat_customer"))
        let logins = runner.calls.filter { $0.arguments == ["login"] }
        #expect(logins.count == 1)
        #expect(logins.first?.environment["PROTON_PASS_PERSONAL_ACCESS_TOKEN"] == "pst_host::key")
        #expect(logins.first?.sessionDirectory == sessions.directory(SessionStore.host).path)
    }

    @Test("a logged-out customer agent logs in with its token from the token vault")
    func agentLogin() throws {
        let (_, customer, global) = try makeTree()
        let runner = runnerWithTokens()
        runner.once(["info"], stdout: Self.hostInfo)     // host: logged in
        runner.once(["info"], status: 1)                 // customer agent: not yet
        let sessions = SessionStore(base: global.sessionsDirectory, runner: runner)
        let export = EnvExport.build(directory: customer.appendingPathComponent("other"), global: global, sessions: sessions) { "pst_host::key" }

        #expect(value(export, "MAVEN_PASSWORD") == .set("s3cr'et"))
        let login = try #require(runner.calls.first { $0.arguments == ["login"] })
        #expect(login.environment["PROTON_PASS_PERSONAL_ACCESS_TOKEN"] == "pst_agent::key")
        #expect(login.sessionDirectory == sessions.directory("agent-kundea").path)
        let read = try #require(runner.calls.first { $0.arguments.contains("pass://lw-tokens/KundeA Proton Agent/note") })
        #expect(read.sessionDirectory == sessions.directory(SessionStore.host).path)
    }

    @Test("without a usable host agent everything is unset, with a hint")
    func noHost() throws {
        let (_, customer, global) = try makeTree()
        let runner = runnerWithTokens()
        runner.on(["info"], status: 1)
        let export = EnvExport.build(directory: customer.appendingPathComponent("web"), global: global,
                                     sessions: SessionStore(base: global.sessionsDirectory, runner: runner)) {
            throw LWError("host-token fehlt")
        }
        #expect(value(export, "ASYLUM_GH_TOKEN") == .unset)
        #expect(value(export, "MAVEN_PASSWORD") == .unset)
        #expect(export.warnings.contains { $0.contains("host-token fehlt") })
        #expect(!runner.calls.contains { $0.arguments.starts(with: ["item", "view"]) })
    }

    @Test("a missing note only unsets its own variable")
    func missingNote() throws {
        let (_, customer, global) = try makeTree()
        let runner = runnerWithTokens()
        runner.on(["item", "view", "pass://lw-tokens/KundeA web GitHub PAT/note"], status: 1, stderr: "Item not found")
        let export = EnvExport.build(directory: customer.appendingPathComponent("web"), global: global,
                                     sessions: SessionStore(base: global.sessionsDirectory, runner: runner)) { "pst_host::key" }
        #expect(value(export, "ASYLUM_GH_TOKEN") == .unset)
        #expect(value(export, "MAVEN_PASSWORD") == .set("s3cr'et"))
        #expect(export.warnings.contains { $0.contains("lw github KundeA --project web") })
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
            "  GH_TOKEN: pass://agent-kundea/Maven/password",
            "  X: pass://agent-kundea/Maven",                       // no field
            "  X: pass://agent-other/Maven/password",               // not granted
            "  X: pass://lw-tokens/KundeA GitHub PAT/note",         // token vault
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
