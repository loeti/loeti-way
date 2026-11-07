import Foundation
import Testing
@testable import LoetiWayKit

@Suite("Projects")
struct ProjectTests {
    let folder = URL(fileURLWithPath: "/Code/customers/KundeA/web")

    func kundeA() throws -> CustomerConfig {
        try CustomerConfig.parse(Fixtures.kundeAWithWeb)
    }

    /// root/customers/KundeA with projects web (own vault and GitHub token, depth 1),
    /// group/api (env only, depth 2), group/deep/x (depth 3, ignored) and broken (invalid YAML).
    func makeTree() throws -> (root: URL, customer: URL) {
        let root = try Fixtures.temporaryDirectory()
        let customer = root.appendingPathComponent("customers/KundeA")
        try Fixtures.write(Fixtures.kundeAWithWeb, to: customer.appendingPathComponent(CustomerConfig.fileName))
        try Fixtures.write("vault: own\ntokens:\n  github:\n    token_name: web_PAT\n", to: customer.appendingPathComponent("web/\(ProjectConfig.fileName)"))
        try Fixtures.write("project: api\nenv:\n  API_KEY: pass://agent-kundea-infra/Api/password\n", to: customer.appendingPathComponent("group/api/\(ProjectConfig.fileName)"))
        try Fixtures.write("{}\n", to: customer.appendingPathComponent("group/deep/x/\(ProjectConfig.fileName)"))
        try Fixtures.write("tokens: [", to: customer.appendingPathComponent("broken/\(ProjectConfig.fileName)"))
        for path in ["web/src", "broken/src", "group/api/src", "other"] {
            try FileManager.default.createDirectory(at: customer.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        return (root, customer)
    }

    @Test("an empty project file exports nothing of its own")
    func empty() throws {
        let project = try ProjectConfig.resolve("{}", folder: folder, customer: try kundeA())
        #expect(project.name == "web")
        #expect(project.vault == nil)
        #expect(project.exports.isEmpty)
    }

    @Test("an own token lies in the project's vault and inherits owner, expiry and permissions")
    func inherits() throws {
        let project = try ProjectConfig.resolve("vault: own\ntokens:\n  github: {}\n", folder: folder, customer: try kundeA())
        let target = try #require(project.tokens.first)
        #expect(project.vault == "agent-kundea-web")
        #expect(target.vault == "agent-kundea-web")
        #expect(target.reference == "pass://agent-kundea-web/GitHub Token/note")
        #expect(target.variable == "GH_TOKEN")
        #expect(target.github == GitHubSettings(owner: "kundea-org", repositories: ["web"], tokenName: "KundeA_web_PAT"))
        #expect(target.label == "KundeA / web")
        #expect(target.command == "lw token github KundeA --project web")
    }

    @Test("project values win")
    func overrides() throws {
        let project = try ProjectConfig.resolve("""
        project: web
        vault: own
        tokens:
          github:
            owner: other-org
            token_name: loeti_loeti-way_PAT
            expires_in_days: 30
            repositories: [web, docs]
            permissions: {contents: read}
        """, folder: folder, customer: try kundeA())
        #expect(project.tokens.first?.github == GitHubSettings(owner: "other-org", expiresInDays: 30, permissions: ["contents": "read"],
                                                               repositories: ["web", "docs"], tokenName: "loeti_loeti-way_PAT"))
    }

    @Test("bad project files are rejected", arguments: [
        "tokens:\n  github: {}\n",                         // own tokens without own vault
        "vault: agent-kundea\n",                           // only 'own'
        "vault: own\ntokens:\n  github: {expires_in_days: 0}\n",
        "project: api\n",                                  // renames the project and its vault
        "github: {owner: x}\n",                            // old format
        "env:\n  X: pass://agent-other/Item/field\n",      // not granted to the customer's agent
        "env:\n  X: pass://lw-tokens/KundeA Proton Agent/note\n",
        "env:\n  PATH: pass://agent-kundea/Item/field\n",
    ])
    func invalid(yaml: String) throws {
        #expect(throws: LWError.self) { try ProjectConfig.resolve(yaml, folder: folder, customer: try kundeA()) }
    }

    @Test("an own vault must be granted to the customer's agent")
    func vaultNotGranted() throws {
        let customer = try CustomerConfig.parse(Fixtures.kundeA)
        #expect(throws: LWError.self) { try ProjectConfig.resolve("vault: own\n", folder: folder, customer: customer) }
    }

    @Test("without an owner anywhere a project token is rejected")
    func noOwner() throws {
        let customer = CustomerConfig(customer: "B", proton: ProtonSettings(vaults: [VaultGrant(name: "agent-b"), VaultGrant(name: "agent-b-web")]))
        #expect(throws: LWError.self) { try ProjectConfig.resolve("vault: own\ntokens: {github: {}}", folder: folder, customer: customer) }
        #expect(try ProjectConfig.resolve("vault: own\ntokens: {github: {owner: b-org}}", folder: folder, customer: customer).tokens.first?.github?.owner == "b-org")
    }

    @Test("projects are found up to two levels below the customer, broken ones reported")
    func discovery() throws {
        let (root, _) = try makeTree()
        let customer = try #require(CustomerLocator.discover(root: root).customers.first)
        #expect(customer.projects.map(\.name) == ["api", "web"])
        #expect(customer.projectFailures.count == 1)
        #expect(customer.projectFailures.first?.file.path.contains("broken") == true)
        #expect(customer.variables == ["API_KEY", "GH_TOKEN"])
    }

    @Test("folder names that give the same vault fail both")
    func sharedVault() throws {
        let (_, customerDir) = try makeTree()
        try Fixtures.write("vault: own\n", to: customerDir.appendingPathComponent("group/Web/\(ProjectConfig.fileName)"))
        let customer = try CustomerLocator.load(file: customerDir.appendingPathComponent(CustomerConfig.fileName))
        #expect(!customer.projects.contains { $0.vault == "agent-kundea-web" })
        #expect(customer.projectFailures.filter { $0.message.contains("mehreren Projekten") }.count == 2)
    }

    @Test("a project replaces the customer's token and adds its env; elsewhere the customer's apply")
    func exports() throws {
        let (root, customerDir) = try makeTree()
        let customer = try CustomerLocator.resolve(name: nil, cwd: customerDir, root: root)
        func exports(_ path: String) throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try customer.exports(for: customerDir.appendingPathComponent(path)).exports.map { ($0.variable, $0.reference) })
        }
        #expect(try exports("other") == ["GH_TOKEN": "pass://agent-kundea/GitHub Token/note"])
        #expect(try exports("web/src") == ["GH_TOKEN": "pass://agent-kundea-web/GitHub Token/note"])
        #expect(try exports("group/api/src") == ["GH_TOKEN": "pass://agent-kundea/GitHub Token/note",
                                                 "API_KEY": "pass://agent-kundea-infra/Api/password"])
        // Inside a broken project, never fall back to the customer's token.
        #expect(throws: LWError.self) { try exports("broken/src") }
    }

    @Test("lw token picks the named project, then what applies around cwd, then the customer")
    func targetSelection() throws {
        let (root, customerDir) = try makeTree()
        let inWeb = customerDir.appendingPathComponent("web/src")
        let customer = try CustomerLocator.resolve(name: nil, cwd: inWeb, root: root)

        #expect(try customer.tokenTarget(.github, project: "WEB", cwd: nil).vault == "agent-kundea-web")
        #expect(try customer.tokenTarget(.github, project: nil, cwd: inWeb).github?.tokenName == "web_PAT")
        #expect(try customer.tokenTarget(.github, project: nil, cwd: customerDir.appendingPathComponent("group/api")).project == nil)
        #expect(try customer.tokenTarget(.github, project: nil, cwd: nil).project == nil)
        // api has no own token: naming it is an error, not the customer's token.
        #expect(throws: LWError.self) { try customer.tokenTarget(.github, project: "api", cwd: nil) }
        #expect(throws: LWError.self) { try customer.tokenTarget(.github, project: "nope", cwd: nil) }
        #expect(throws: LWError.self) { try customer.tokenTarget(.github, project: nil, cwd: customerDir.appendingPathComponent("broken/src")) }
    }

    @Test("the project template resolves once the vault is granted")
    func scaffold() throws {
        let customer = try kundeA()
        let template = Scaffold.projectTemplate(project: "web", customer: customer, githubOwner: nil)
        let project = try ProjectConfig.resolve(template, folder: folder, customer: customer)
        #expect(project.vault == "agent-kundea-web")
        #expect(project.tokens.first?.github?.owner == "kundea-org")
        #expect(project.tokens.first?.github?.repositories == ["web"])
        #expect(!template.contains("project:"))

        // The owner is written out, so the project survives the customer dropping its token.
        var withoutTokens = customer
        withoutTokens.tokens = nil
        #expect(try ProjectConfig.resolve(template, folder: folder, customer: withoutTokens).tokens.first?.github?.owner == "kundea-org")
        // Without any owner the token stays commented out.
        #expect(try ProjectConfig.resolve(Scaffold.projectTemplate(project: "web", customer: withoutTokens, githubOwner: nil), folder: folder, customer: withoutTokens).tokens.isEmpty)
    }

    @Test("project files go into .git/info/exclude once, and only in a git repo")
    func gitExclude() throws {
        let plain = try Fixtures.temporaryDirectory()
        #expect(try Scaffold.excludeFromGit(Scaffold.projectFiles, in: plain).isEmpty)

        let repo = try Fixtures.temporaryDirectory()
        try Fixtures.write("*.log\n/.envrc\n", to: repo.appendingPathComponent(".git/info/exclude"))
        #expect(try Scaffold.excludeFromGit(Scaffold.projectFiles, in: repo) == [ProjectConfig.fileName])
        #expect(try Scaffold.excludeFromGit(Scaffold.projectFiles, in: repo).isEmpty)
        let text = try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(text == "*.log\n/.envrc\n# lw (loeti-way)\n/\(ProjectConfig.fileName)\n")
    }
}
