import Foundation
import Testing
@testable import LoetiWayKit

@Suite("Project PATs")
struct ProjectTests {
    let folder = URL(fileURLWithPath: "/Code/customers/KundeA/web")

    func kundeA() throws -> CustomerConfig {
        try CustomerConfig.parse(Fixtures.kundeA)
    }

    /// root/customers/KundeA with projects web (depth 1), group/api (depth 2), group/deep/x
    /// (depth 3, ignored) and broken (invalid YAML).
    func makeTree() throws -> (root: URL, customer: URL) {
        let root = try Fixtures.temporaryDirectory()
        let customer = root.appendingPathComponent("customers/KundeA")
        try Fixtures.write(Fixtures.kundeA, to: customer.appendingPathComponent(CustomerConfig.fileName))
        try Fixtures.write("github:\n  token_name: web_PAT\n", to: customer.appendingPathComponent("web/\(ProjectConfig.fileName)"))
        try Fixtures.write("project: api\n", to: customer.appendingPathComponent("group/api/\(ProjectConfig.fileName)"))
        try Fixtures.write("{}\n", to: customer.appendingPathComponent("group/deep/x/\(ProjectConfig.fileName)"))
        try Fixtures.write("github: [", to: customer.appendingPathComponent("broken/\(ProjectConfig.fileName)"))
        try FileManager.default.createDirectory(at: customer.appendingPathComponent("web/src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customer.appendingPathComponent("broken/src"), withIntermediateDirectories: true)
        return (root, customer)
    }

    @Test("a project inherits owner, expiry and permissions from the customer")
    func inherits() throws {
        let project = try ProjectConfig.resolve("{}", folder: folder, customer: try kundeA())
        #expect(project.name == "web")
        #expect(project.github.settings.owner == "kundea-org")
        #expect(project.github.settings.expiresInDays == 90)
        #expect(project.github.settings.permissions == GitHubSettings.defaultPermissions)
        #expect(project.github.settings.repositories == ["web"])
        #expect(project.github.tokenItem == "KundeA web GitHub PAT")
        #expect(project.github.tokenName == "KundeA_web_PAT")
        #expect(project.github.label == "KundeA / web")
    }

    @Test("a project folder with a space is refused, its note could be another customer's")
    func spaceInFolder() throws {
        // KundeA + "x y" and a customer "KundeA x" + "y" would both read "KundeA x y GitHub PAT".
        let spaced = URL(fileURLWithPath: "/Code/customers/KundeA/x y")
        #expect(throws: LWError.self) { try ProjectConfig.resolve("{}", folder: spaced, customer: try kundeA()) }
        #expect(ProjectConfig.nameProblem("x y")?.contains("'x-y'") == true)
        #expect(ProjectConfig.nameProblem("x-y") == nil)
    }

    @Test("project values win")
    func overrides() throws {
        let project = try ProjectConfig.resolve("""
        project: web
        github:
          owner: other-org
          token_name: loeti_loeti-way_PAT
          expires_in_days: 30
          repositories: [web, docs]
          permissions: {contents: read}
        """, folder: folder, customer: try kundeA())
        #expect(project.name == "web")
        #expect(project.github.settings == GitHubSettings(owner: "other-org", expiresInDays: 30, permissions: ["contents": "read"],
                                                          repositories: ["web", "docs"], tokenName: "loeti_loeti-way_PAT"))
        #expect(project.github.tokenItem == "KundeA web GitHub PAT")
        #expect(project.github.tokenName == "loeti_loeti-way_PAT")
    }

    @Test("without an owner anywhere, or with bad values, a project is rejected")
    func invalid() throws {
        let noGitHub = CustomerConfig(customer: "B", proton: ProtonSettings(vaults: [VaultGrant(name: "agent-b")]))
        #expect(throws: LWError.self) { try ProjectConfig.resolve("{}", folder: folder, customer: noGitHub) }
        #expect(try ProjectConfig.resolve("github: {owner: b-org}", folder: folder, customer: noGitHub).github.settings.owner == "b-org")
        #expect(throws: LWError.self) { try ProjectConfig.resolve("github: {expires_in_days: 0}", folder: folder, customer: try kundeA()) }
        // Agent-writable: 'project' must not rename the project and with it its note.
        #expect(throws: LWError.self) { try ProjectConfig.resolve("project: api", folder: folder, customer: try kundeA()) }
        // The file lies where agents can write; it must not choose the note lw reads and writes.
        #expect(throws: LWError.self) { try ProjectConfig.resolve("github: {token_item: KundeB GitHub PAT}", folder: folder, customer: try kundeA()) }
    }

    @Test("projects are found up to two levels below the customer, broken ones reported")
    func discovery() throws {
        let (root, _) = try makeTree()
        let customer = try #require(CustomerLocator.discover(root: root).customers.first)
        #expect(customer.projects.map(\.name) == ["api", "web"])
        #expect(customer.projectFailures.count == 1)
        #expect(customer.projectFailures.first?.file.path.contains("broken") == true)
        #expect(customer.githubTargets.map(\.label) == ["KundeA", "KundeA / api", "KundeA / web"])
    }

    @Test("two PATs can't share a note in the token vault")
    func duplicateItem() throws {
        let (_, customerDir) = try makeTree()
        let config = Fixtures.kundeA.replacingOccurrences(of: "  expiration: 1m\n", with: "  expiration: 1m\n  token_item: KundeA dup GitHub PAT\n")
        try Fixtures.write(config, to: customerDir.appendingPathComponent(CustomerConfig.fileName))
        try Fixtures.write("{}\n", to: customerDir.appendingPathComponent("dup/\(ProjectConfig.fileName)"))
        let customer = try CustomerLocator.load(file: customerDir.appendingPathComponent(CustomerConfig.fileName))
        #expect(customer.projectFailures.contains { $0.message.contains("mehrfach vergeben") })
    }

    @Test("a project can't take over another project's note, and shared notes fail for both")
    func takeover() throws {
        let (_, customerDir) = try makeTree()
        let customerFile = customerDir.appendingPathComponent(CustomerConfig.fileName)
        // An agent in group/api renames its project to web: api is rejected, web keeps its PAT.
        try Fixtures.write("project: web\n", to: customerDir.appendingPathComponent("group/api/\(ProjectConfig.fileName)"))
        var customer = try CustomerLocator.load(file: customerFile)
        #expect(customer.projects.map(\.name) == ["web"])
        #expect(customer.projectFailures.contains { $0.file.path.contains("group/api") })

        // Two folders named web: neither gets the note, regardless of which is found first.
        try Fixtures.write("{}\n", to: customerDir.appendingPathComponent("a/web/\(ProjectConfig.fileName)"))
        customer = try CustomerLocator.load(file: customerFile)
        #expect(!customer.projects.contains { $0.name == "web" })
        #expect(customer.projectFailures.filter { $0.message.contains("mehrfach vergeben") }.count == 2)
    }

    @Test("a project can't use another customer's note")
    func crossCustomerItem() throws {
        let (root, customerDir) = try makeTree()
        // Customer "KundeA web" owns "KundeA web GitHub PAT", the note of KundeA's project web.
        let other = Fixtures.kundeA.replacingOccurrences(of: "customer: KundeA", with: "customer: KundeA web")
        try Fixtures.write(other, to: root.appendingPathComponent("customers/KundeAWeb/\(CustomerConfig.fileName)"))
        let kundeA = try CustomerLocator.load(file: customerDir.appendingPathComponent(CustomerConfig.fileName))
        let web = try kundeA.githubTarget(project: "web", cwd: nil)
        #expect(throws: LWError.self) { try CustomerLocator.ensureUnclaimed(web, owner: kundeA, root: root, registry: CustomerRegistry()) }
        try CustomerLocator.ensureUnclaimed(try kundeA.githubTarget(project: "api", cwd: nil), owner: kundeA, root: root, registry: CustomerRegistry())
        try CustomerLocator.ensureUnclaimed(try #require(kundeA.config.githubTarget(directory: kundeA.directory)), owner: kundeA, root: root, registry: CustomerRegistry())
    }

    @Test("a registered customer claims its notes even when its config isn't found below the root")
    func registeredClaim() throws {
        let (root, customerDir) = try makeTree()
        let kundeA = try CustomerLocator.load(file: customerDir.appendingPathComponent(CustomerConfig.fileName))
        let web = try kundeA.githubTarget(project: "web", cwd: nil)
        let elsewhere = CustomerRegistry.Entry(directory: "/elsewhere/KundeAWeb", customer: "KundeA web", agent: "asylum-kundeaweb",
                                               protonTokenItem: "KundeA web Proton Agent", githubTokenItem: "KundeA web GitHub PAT")
        let registry = CustomerRegistry(entries: [elsewhere, CustomerRegistry.Entry(kundeA)])
        #expect(throws: LWError.self) { try CustomerLocator.ensureUnclaimed(web, owner: kundeA, root: root, registry: registry) }
        // Its own registration doesn't count against it.
        try CustomerLocator.ensureUnclaimed(try kundeA.githubTarget(project: "api", cwd: nil), owner: kundeA, root: root, registry: registry)
        try CustomerLocator.ensureUnclaimed(try #require(kundeA.config.githubTarget(directory: kundeA.directory)), owner: kundeA, root: root, registry: registry)
    }

    @Test("lw github picks the named project, then the one around cwd, then the customer")
    func targetSelection() throws {
        let (root, customerDir) = try makeTree()
        let inWeb = customerDir.appendingPathComponent("web/src")
        let customer = try CustomerLocator.resolve(name: nil, cwd: inWeb, root: root)
        #expect(customer.config.customer == "KundeA")

        #expect(try customer.githubTarget(project: "API", cwd: inWeb).project == "api")
        #expect(try customer.githubTarget(project: nil, cwd: inWeb).tokenName == "web_PAT")
        #expect(try customer.githubTarget(project: nil, cwd: customerDir).project == nil)
        #expect(try customer.githubTarget(project: nil, cwd: nil).project == nil)
        #expect(throws: LWError.self) { try customer.githubTarget(project: "nope", cwd: nil) }
        // Inside a broken project, never fall back to the customer's wider token.
        #expect(throws: LWError.self) { try customer.githubTarget(project: nil, cwd: customerDir.appendingPathComponent("broken/src")) }
    }

    @Test("the project template resolves")
    func scaffold() throws {
        let customer = try kundeA()
        let template = Scaffold.projectTemplate(project: "web", customer: customer, githubOwner: nil)
        let project = try ProjectConfig.resolve(template, folder: folder, customer: customer)
        #expect(project.github.settings.owner == "kundea-org")
        #expect(project.github.settings.repositories == ["web"])

        // The owner is written out, so the project survives the customer dropping its github section.
        var withoutGitHub = customer
        withoutGitHub.github = nil
        #expect(try ProjectConfig.resolve(template, folder: folder, customer: withoutGitHub).github.settings.owner == "kundea-org")

        let withOwner = Scaffold.projectTemplate(project: "web", customer: customer, githubOwner: "other-org")
        #expect(try ProjectConfig.resolve(withOwner, folder: folder, customer: customer).github.settings.owner == "other-org")
        #expect(!template.contains("project:"))
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
