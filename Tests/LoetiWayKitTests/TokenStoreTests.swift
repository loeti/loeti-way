import Foundation
import Testing
@testable import LoetiWayKit

@Suite("Token store")
struct TokenStoreTests {
    @Test("the token goes over stdin, the new note is created before old ones are deleted")
    func save() throws {
        let runner = FakeRunner()
        runner.on(["item", "list"], stdout: """
        {"items": [
          {"id": "old", "share_id": "s", "title": "KundeA Proton Agent", "state": "Active"},
          {"id": "other", "share_id": "s", "title": "KundeB Proton Agent", "state": "Active"}
        ]}
        """)
        let store = TokenStore(pass: PassCLI(runner: runner), vault: "Agent Tokens")
        try store.save(title: "KundeA Proton Agent", token: "pst_secret::KEY")

        #expect(runner.mutations == [
            "item create note --vault-name Agent Tokens --from-template -",
            "item delete --share-id s --item-id old",
        ])
        for call in runner.calls {
            #expect(!call.arguments.joined().contains("pst_secret"))
        }
        let stdin = try #require(runner.calls.first { $0.arguments.contains("create") }?.stdin)
        let template = try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        #expect(template["title"] as? String == "KundeA Proton Agent")
        #expect(template["note"] as? String == "pst_secret::KEY")
    }

    @Test("a missing vault fails before anything is created, with a hint")
    func missingVault() {
        let runner = FakeRunner()
        runner.on(["item", "list"], status: 1, stderr: "Vault not found")
        let store = TokenStore(pass: PassCLI(runner: runner), vault: "Agent Tokens")
        do {
            try store.save(title: "T", token: "x")
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("pass-cli vault create --name \"Agent Tokens\""))
        }
        #expect(runner.mutations.isEmpty)
    }

    @Test("read trims the trailing newline")
    func read() throws {
        let runner = FakeRunner()
        runner.on(["item", "view"], stdout: "github_pat_abc\n")
        let store = TokenStore(pass: PassCLI(runner: runner), vault: "Agent Tokens")
        #expect(try store.read(title: "KundeA GitHub PAT") == "github_pat_abc")
        #expect(runner.calls.first?.arguments == ["item", "view", "pass://Agent Tokens/KundeA GitHub PAT/note"])
    }
}
