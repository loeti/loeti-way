import Foundation
import Testing
@testable import LoetiWayKit

@Suite("pass-cli wrapper")
struct PassCLITests {
    @Test("agent list: pat_id, name, expire_time (may be null)")
    func listAgents() throws {
        let runner = FakeRunner()
        runner.on(["agent", "list"], stdout: """
        [
          {"pat_id": "pat_1", "name": "asylum-kundea", "expire_time": 1800000000},
          {"pat_id": "pat_2", "name": "other", "expire_time": null}
        ]
        """)
        let agents = try PassCLI(runner: runner).listAgents()
        #expect(agents == [
            ProtonAgent(id: "pat_1", name: "asylum-kundea", expires: Date(timeIntervalSince1970: 1_800_000_000)),
            ProtonAgent(id: "pat_2", name: "other", expires: nil),
        ])
        #expect(runner.calls.first?.arguments == ["agent", "list", "--output", "json"])
    }

    @Test("list-access: tagged by type, roles as string or custom object")
    func listAccess() throws {
        let runner = FakeRunner()
        runner.on(["pat", "access", "list-access"], stdout: """
        [
          {"type": "vault", "share_id": "s1", "role": "Viewer", "vault_name": "agent-kundea"},
          {"type": "item", "share_id": "s2", "role": "Editor", "expire_time": 1, "item_title": "DB", "item_id": "i1"},
          {"type": "vault", "share_id": "s3", "role": {"Custom": {"name": "x", "permission": 7}}, "vault_name": "Odd"}
        ]
        """)
        let grants = try PassCLI(runner: runner).listAccess(agentID: "pat_1")
        #expect(grants == [
            AccessGrant(target: .vault, shareID: "s1", name: "agent-kundea", role: "viewer"),
            AccessGrant(target: .item, shareID: "s2", name: "DB", role: "editor"),
            AccessGrant(target: .vault, shareID: "s3", name: "Odd", role: "custom"),
        ])
        #expect(runner.calls.first?.arguments.contains("pat_1") == true)
    }

    @Test("create and renew return the bare token")
    func tokens() throws {
        let runner = FakeRunner()
        let output = #"{"token": "PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_abc::KEY", "instruction": "..."}"#
        runner.on(["agent", "create"], stdout: output)
        runner.on(["agent", "renew"], stdout: output)
        let pass = PassCLI(runner: runner)
        #expect(try pass.createAgent(name: "asylum-kundea", lifetime: .threeMonths) == "pst_abc::KEY")
        #expect(try pass.renewAgent(name: "asylum-kundea", lifetime: .oneYear) == "pst_abc::KEY")
        #expect(runner.calls.map(\.arguments) == [
            ["agent", "create", "asylum-kundea", "--expiration", "3m"],
            ["agent", "renew", "asylum-kundea", "--expiration", "1y", "--output", "json"],
        ])
    }

    @Test("errors carry pass-cli's message; 127 means not installed")
    func errors() {
        let runner = FakeRunner()
        runner.on(["agent", "list"], status: 1, stderr: "Vault not found\n")
        runner.on(["item", "list"], status: 127)
        let pass = PassCLI(runner: runner)
        #expect(throws: LWError("pass-cli agent list ist fehlgeschlagen: Vault not found")) {
            try pass.listAgents()
        }
        #expect(throws: PassCLI.notFound) { try pass.listItems(vault: "X") }
    }

    @Test("a token session is refused where the account is needed")
    func session() throws {
        let runner = FakeRunner()
        runner.on(["info"], stdout: "- Release track: stable\n- Personal Access Token: asylum-kundea\n")
        #expect(throws: LWError.self) { try PassCLI(runner: runner).session().requireAccount() }

        runner.on(["info"], stdout: "- Release track: stable\n- ID: u1\n- Username: loeti\n")
        try PassCLI(runner: runner).session().requireAccount()

        runner.on(["info"], status: 1)
        #expect(throws: LWError.self) { try PassCLI(runner: runner).session().requireAccount() }
    }

    @Test("session directory and reason go into the environment, the token never into arguments")
    func environment() throws {
        let runner = FakeRunner()
        let pass = PassCLI(runner: runner, sessionDirectory: URL(fileURLWithPath: "/s/host"), reason: "test")
        try pass.login(token: "PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_abc::key")
        _ = try? pass.read("pass://lw-tokens/X/note")
        let login = try #require(runner.calls.first)
        #expect(login.arguments == ["login"])
        #expect(login.environment["PROTON_PASS_PERSONAL_ACCESS_TOKEN"] == "pst_abc::key")
        #expect(runner.calls.allSatisfy { $0.sessionDirectory == "/s/host" && $0.environment["PROTON_PASS_AGENT_REASON"] == "test" })
        #expect(!runner.calls.flatMap(\.arguments).contains { $0.contains("pst_") })
        // Only the login sees the token.
        #expect(runner.calls.dropFirst().allSatisfy { $0.environment["PROTON_PASS_PERSONAL_ACCESS_TOKEN"] == nil })

        runner.on(["login"], status: 1, stderr: "bad")
        #expect(throws: LWError.self) { try pass.login(token: "pst_abc::key") }
    }

    @Test("the child process never inherits PROTON_PASS_* from the shell")
    func childEnvironment() {
        let child = ProcessRunner.childEnvironment(
            ["PATH": "/bin", "PROTON_PASS_PERSONAL_ACCESS_TOKEN": "pst_x", "PROTON_PASS_SESSION_DIR": "/default"],
            adding: ["PROTON_PASS_SESSION_DIR": "/lw/host"]
        )
        #expect(child == ["PATH": "/bin", "PROTON_PASS_SESSION_DIR": "/lw/host"])
    }

    @Test("the session tells account, token and logged out apart")
    func sessionKinds() throws {
        let runner = FakeRunner()
        let pass = PassCLI(runner: runner)
        runner.on(["info"], stdout: "- Release track: stable\n- ID: u1\n- Username: loeti\n")
        #expect(try pass.session() == .account(username: "loeti"))
        #expect("\(try pass.session())".contains("loeti"))

        runner.on(["info"], stdout: "- Release track: stable\n- Personal Access Token: asylum-kundea\n")
        #expect(try pass.session() == .token(name: "asylum-kundea"))
        // As pass-cli 2.7.0 prints it.
        runner.on(["info"], stdout: "- Release track: stable\n- Personal Access Token: [Agent] lw-host\n")
        #expect(try pass.session() == .token(name: "lw-host"))
        #expect(throws: LWError.self) { try pass.session().requireAccount() }

        runner.on(["info"], status: 1, stderr: "not logged in")
        #expect(try pass.session() == .loggedOut)

        runner.on(["info"], status: 127)
        #expect(throws: LWError.self) { try pass.session() }
    }

    @Test("logout calls pass-cli logout")
    func logout() throws {
        let runner = FakeRunner()
        try PassCLI(runner: runner).logout()
        #expect(runner.mutations == ["logout"])

        runner.on(["logout"], status: 1, stderr: "boom")
        #expect(throws: LWError.self) { try PassCLI(runner: runner).logout() }
    }

    @Test("item list skips nothing but marks trashed items")
    func listItems() throws {
        let runner = FakeRunner()
        runner.on(["item", "list"], stdout: """
        {"items": [
          {"id": "i1", "share_id": "s", "vault_id": "v", "state": "Active", "title": "KundeA Proton Agent", "item_type": "note"},
          {"id": "i2", "share_id": "s", "vault_id": "v", "state": "Trashed", "title": "Old", "item_type": "note"},
          {"id": "i3", "share_id": "s", "vault_id": "v", "state": {"weird": 1}, "title": "Unknown state", "item_type": "note"}
        ], "folders": []}
        """)
        let items = try PassCLI(runner: runner).listItems(vault: "lw-tokens")
        #expect(items.map(\.isActive) == [true, false, true])
    }
}
