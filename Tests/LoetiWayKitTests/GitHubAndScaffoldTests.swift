import Foundation
import Testing
@testable import LoetiWayKit

@Suite("GitHub PAT")
struct GitHubTests {
    @Test("the creation URL carries name, owner, expiry and permissions")
    func creationURL() throws {
        let settings = GitHubSettings(owner: "kundea-org", expiresInDays: 30, permissions: ["pull_requests": "write", "contents": "read"])
        let target = GitHubTarget(customer: "KundeA", project: nil, settings: settings, tokenItem: "KundeA GitHub PAT", tokenName: "KundeA Asylum", directory: URL(fileURLWithPath: "/Code/KundeA"))
        let url = GitHubPAT.creationURL(target: target)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.path == "/settings/personal-access-tokens/new")
        #expect(query["name"] == "KundeA Asylum")
        #expect(query["target_name"] == "kundea-org")
        #expect(query["expires_in"] == "30")
        #expect(query["contents"] == "read")
        #expect(query["pull_requests"] == "write")
    }

    @Test("expiration header in both formats GitHub uses")
    func expirationHeader() throws {
        let utc = try #require(GitHubPAT.parseExpiration("2027-02-03 12:00:00 UTC"))
        let offset = try #require(GitHubPAT.parseExpiration("2027-02-03 13:00:00 +0100"))
        #expect(utc == offset)
        #expect(utc.timeIntervalSince1970 == 1_801_656_000)
        #expect(GitHubPAT.parseExpiration("soon") == nil)
    }

    @Test("only fine-grained tokens are accepted")
    func fineGrained() {
        #expect(GitHubPAT.isFineGrained("github_pat_11ABC"))
        #expect(!GitHubPAT.isFineGrained("ghp_classic"))
    }
}

@Suite("Scaffold")
struct ScaffoldTests {
    @Test("the template parses and validates")
    func templateRoundTrip() throws {
        for owner in [nil, "kundea-org"] {
            let config = try CustomerConfig.parse(Scaffold.configTemplate(customer: "Kunde: A", githubOwner: owner))
            #expect(config.customer == "Kunde: A")
            #expect(config.proton.vaults == [VaultGrant(name: "agent-kunde-a")])
            #expect(config.github?.owner == owner)
            try config.validate(tokenVault: "lw-tokens")
        }
    }

    @Test(".envrc holds references only and quotes for the shell")
    func envrc() throws {
        var config = try CustomerConfig.parse(Fixtures.kundeA)
        config.proton.tokenItem = "Say \"hi\" $HOME"
        let text = Scaffold.envrc(config: config, tokenVault: "lw-tokens")
        #expect(text.contains(#"export ASYLUM_PROTON_PASS_PAT="$(pass-cli item view "pass://lw-tokens/Say \"hi\" \$HOME/note")""#))
        #expect(text.contains(#"export ASYLUM_GH_TOKEN="$(pass-cli item view "pass://lw-tokens/KundeA GitHub PAT/note")""#))

        config.github = nil
        #expect(!Scaffold.envrc(config: config, tokenVault: "lw-tokens").contains("ASYLUM_GH_TOKEN"))
    }
}

@Suite("Status")
struct StatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func customer() throws -> LoadedCustomer {
        LoadedCustomer(config: try CustomerConfig.parse(Fixtures.kundeA), file: URL(fileURLWithPath: "/Code/customers/KundeA/.loeti-way.yaml"))
    }

    @Test("a fully set up customer needs no attention")
    func healthy() async throws {
        let runner = FakeRunner()
        runner.on(["agent", "list"], stdout: #"[{"pat_id": "p1", "name": "asylum-kundea", "expire_time": 1805000000}]"#)
        runner.on(["pat", "access", "list-access"], stdout: """
        [{"type": "vault", "share_id": "s1", "role": "Viewer", "vault_name": "agent-kundea"},
         {"type": "vault", "share_id": "s2", "role": "Editor", "vault_name": "agent-kundea-infra"}]
        """)
        runner.on(["item", "list"], stdout: """
        {"items": [{"id": "1", "share_id": "t", "title": "KundeA Proton Agent"},
                   {"id": "2", "share_id": "t", "title": "KundeA GitHub PAT"}]}
        """)
        runner.on(["item", "view"], stdout: "github_pat_x\n")
        let pass = PassCLI(runner: runner)
        let checker = FakeChecker(result: .success(GitHubTokenInfo(login: "loeti", expires: now.addingTimeInterval(60 * 86_400))))
        let collector = StatusCollector(pass: pass, store: TokenStore(pass: pass, vault: "lw-tokens"), checker: checker)

        let status = try #require(try await collector.collect([customer()]).first)
        #expect(status.plan?.isEmpty == true)
        #expect(status.protonTokenStored == true)
        #expect(status.github == .ok(GitHubTokenInfo(login: "loeti", expires: now.addingTimeInterval(60 * 86_400))))
        #expect(!status.needsAttention(now: now, warnDays: 14))
        #expect(status.render(now: now, warnDays: 14, tokenVault: "lw-tokens").contains("@loeti"))
        #expect(runner.mutations.isEmpty)
    }

    @Test("missing agent, missing tokens and near expiry are flagged")
    func problems() async throws {
        let runner = FakeRunner()
        runner.on(["agent", "list"], stdout: "[]")
        runner.on(["item", "list"], stdout: #"{"items": []}"#)
        let pass = PassCLI(runner: runner)
        let collector = StatusCollector(pass: pass, store: TokenStore(pass: pass, vault: "lw-tokens"), checker: nil)

        let status = try #require(try await collector.collect([customer()]).first)
        #expect(status.agent == nil)
        #expect(status.protonTokenStored == false)
        #expect(status.github == .tokenMissing)
        #expect(status.needsAttention(now: now, warnDays: 14))
        let text = status.render(now: now, warnDays: 14, tokenVault: "lw-tokens")
        #expect(text.contains("lw apply KundeA"))
        #expect(text.contains("lw github KundeA"))

        var soon = CustomerStatus(customer: try customer())
        soon.agent = ProtonAgent(id: "p", name: "asylum-kundea", expires: now.addingTimeInterval(5 * 86_400))
        soon.protonTokenStored = true
        soon.plan = AccessPlan()
        #expect(soon.needsAttention(now: now, warnDays: 14))
        #expect(!soon.needsAttention(now: now, warnDays: 3))
    }
}
