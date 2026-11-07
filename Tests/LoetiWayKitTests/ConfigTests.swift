import Foundation
import Testing
@testable import LoetiWayKit

@Suite("Customer config")
struct ConfigTests {
    @Test("defaults are filled in")
    func defaults() throws {
        let config = try CustomerConfig.parse(Fixtures.kundeA)
        #expect(config.customer == "KundeA")
        #expect(config.agentName == "asylum-kundea")
        #expect(config.protonTokenItem == "KundeA Proton Agent")
        #expect(config.githubTokenItem == "KundeA GitHub PAT")
        #expect(config.proton.expiration == .oneMonth)
        #expect(config.proton.vaults == [VaultGrant(name: "agent-kundea"), VaultGrant(name: "agent-kundea-infra", role: .editor)])
        #expect(config.github?.expiresInDays == 90)
        #expect(config.github?.permissions == ["contents": "write", "pull_requests": "write"])
        #expect(config.github?.repositories == ["web", "api"])
    }

    @Test("overrides win over defaults")
    func overrides() throws {
        let config = try CustomerConfig.parse("""
        customer: Müller AG
        proton:
          agent: custom-agent
          token_item: Müller Token
          vaults: [{name: Müller}]
        """)
        #expect(config.agentName == "custom-agent")
        #expect(config.protonTokenItem == "Müller Token")
        #expect(config.proton.expiration == .threeMonths)
        #expect(config.github == nil)
    }

    @Test("unknown role and lifetime are rejected with a readable message")
    func invalidValues() {
        #expect(throws: LWError.self) {
            try CustomerConfig.parse("customer: A\nproton:\n  vaults: [{name: A, role: owner}]\n")
        }
        #expect(throws: LWError.self) {
            try CustomerConfig.parse("customer: A\nproton:\n  expiration: 2y\n  vaults: [{name: A}]\n")
        }
        #expect(throws: LWError("Pflichtfeld 'customer' fehlt")) {
            try CustomerConfig.parse("proton:\n  vaults: [{name: A}]\n")
        }
    }

    @Test("the token vault can never be granted to an agent")
    func tokenVaultIsRejected() throws {
        let config = CustomerConfig(customer: "A", proton: ProtonSettings(vaults: [VaultGrant(name: "lw-tokens")]))
        #expect(throws: LWError.self) { try config.validate(tokenVault: "lw-tokens") }
        try CustomerConfig.parse(Fixtures.kundeA).validate(tokenVault: "lw-tokens")
    }

    @Test("only agent- vaults can be granted", arguments: [
        "KundeA", "Agent-kundea", "agent-", "agent-Kunde A", "agent-kunde--a", "agent-kunde-", "lw-kundea", "agent-kundeä",
    ])
    func nonAgentVaultIsRejected(name: String) {
        let config = CustomerConfig(customer: "KundeA", proton: ProtonSettings(vaults: [VaultGrant(name: name)]))
        #expect(throws: LWError.self) { try config.validate(tokenVault: "lw-tokens") }
    }

    @Test("agent- vaults in lowercase words pass", arguments: ["agent-kundea", "agent-kunde-a-infra", "agent-2026"])
    func agentVaultIsAccepted(name: String) throws {
        let config = CustomerConfig(customer: "KundeA", proton: ProtonSettings(vaults: [VaultGrant(name: name)]))
        try config.validate(tokenVault: "lw-tokens")
    }

    @Test("the rejection suggests an agent- name")
    func vaultSuggestion() {
        let config = CustomerConfig(customer: "KundeA", proton: ProtonSettings(vaults: [VaultGrant(name: "KundeA Infra")]))
        #expect(throws: LWError("Vault 'KundeA Infra' kann keinem Agent freigegeben werden: Vaults für Agents heissen agent-<name>, z.B. agent-kundea-infra")) {
            try config.validate(tokenVault: "lw-tokens")
        }
    }

    @Test("the token vault must start with lw-")
    func tokenVaultName() throws {
        let root = URL(fileURLWithPath: "/Code")
        try GlobalConfig(root: root).validate()
        try GlobalConfig(root: root, tokenVault: "lw-agent-tokens").validate()
        for name in ["Agent Tokens", "agent-tokens", "tokens", "lw-", "lw-Tokens"] {
            #expect(throws: LWError.self) { try GlobalConfig(root: root, tokenVault: name).validate() }
        }
    }

    @Test("validation collects every problem")
    func validationProblems() {
        let config = CustomerConfig(
            customer: "A/B",
            proton: ProtonSettings(vaults: [VaultGrant(name: "X"), VaultGrant(name: "X")]),
            github: GitHubSettings(owner: "", expiresInDays: 400, permissions: ["contents": "full"])
        )
        do {
            try config.validate(tokenVault: "lw-tokens")
            Issue.record("expected an error")
        } catch {
            let message = "\(error)"
            for fragment in ["enthält '/'", "mehrfach", "agent-<name>", "github.owner", "expires_in_days", "contents"] {
                #expect(message.contains(fragment), "missing: \(fragment)")
            }
        }
    }

    @Test("slugs are lowercase ASCII", arguments: [
        ("KundeA", "kundea"),
        ("Müller & Söhne AG", "muller-sohne-ag"),
        ("  firma  ", "firma"),
    ])
    func slug(input: String, expected: String) {
        #expect(Slug.make(input) == expected)
    }

    @Test("global config: environment beats file beats defaults")
    func globalConfig() throws {
        let home = try Fixtures.temporaryDirectory()
        let environment = ["HOME": home.path]
        var config = try GlobalConfig.load(environment: environment)
        #expect(config.root.path == GlobalConfig.defaultRoot)
        #expect(config.tokenVault == "lw-tokens")

        try Fixtures.write("root: ~/Code\ntoken_vault: Tokens\nwarn_days: 30\n",
                           to: home.appendingPathComponent(".config/loeti-way/config.yaml"))
        config = try GlobalConfig.load(environment: environment)
        #expect(config.root.path == home.appendingPathComponent("Code").path)
        #expect(config.tokenVault == "Tokens")
        #expect(config.warnDays == 30)

        config = try GlobalConfig.load(environment: environment.merging(["LW_ROOT": "/x"]) { $1 })
        #expect(config.root.path == "/x")
    }
}
