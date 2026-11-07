import Foundation
import Testing
@testable import LoetiWayKit

@Suite("GitHub PAT")
struct GitHubTests {
    @Test("the creation URL carries name, owner, expiry and permissions")
    func creationURL() throws {
        let settings = GitHubSettings(owner: "kundea-org", expiresInDays: 30, permissions: ["pull_requests": "write", "contents": "read"], tokenName: "KundeA_PAT")
        let target = TokenTarget(customer: "KundeA", project: nil, vault: "agent-kundea", variable: "GH_TOKEN", settings: .github(settings), directory: URL(fileURLWithPath: "/Code/KundeA"))
        let url = GitHubPAT.creationURL(target: target, settings: settings)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.path == "/settings/personal-access-tokens/new")
        #expect(query["name"] == "KundeA_PAT")
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
            #expect(config.tokens?.github?.owner == owner)
            try config.validate(tokenVault: "lw-tokens")
        }
    }

    @Test(".envrc only calls lw env: no secrets, no references, no pass-cli")
    func envrc() throws {
        #expect(Scaffold.envrc.contains(#"eval "$(lw env)""#))
        #expect(!Scaffold.envrc.contains("pass://"))
        #expect(!Scaffold.envrc.contains("pass-cli item"))
    }

    @Test("no Proton token goes into the container, env values do")
    func asylumSnippet() {
        let snippet = Scaffold.asylumConfigSnippet(variables: ["MAVEN_PASSWORD"])
        #expect(snippet.contains("GH_TOKEN: LW_ENV_GH_TOKEN"))
        #expect(snippet.contains("MAVEN_PASSWORD: LW_ENV_MAVEN_PASSWORD"))
        #expect(!snippet.contains("PROTON_PASS"))
    }
}
