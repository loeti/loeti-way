import Foundation
import Testing
@testable import LoetiWayKit

@Suite("Customer locator")
struct LocatorTests {
    /// root/customers/KundeA, root/customers/KundeB (broken), root/loeti, plus a nested
    /// config inside KundeA that must not be found.
    func makeTree() throws -> URL {
        let root = try Fixtures.temporaryDirectory()
        let name = CustomerConfig.fileName
        try Fixtures.write(Fixtures.kundeA, to: root.appendingPathComponent("customers/KundeA/\(name)"))
        try Fixtures.write("customer: [", to: root.appendingPathComponent("customers/KundeB/\(name)"))
        try Fixtures.write("customer: loeti\nproton:\n  vaults: [{name: loeti}]\n", to: root.appendingPathComponent("loeti/\(name)"))
        try Fixtures.write("customer: Nested\nproton:\n  vaults: [{name: N}]\n", to: root.appendingPathComponent("customers/KundeA/repo/\(name)"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("customers/KundeA/repo/src"), withIntermediateDirectories: true)
        return root
    }

    @Test("discovers customers and collects broken configs")
    func discover() throws {
        let root = try makeTree()
        let discovery = CustomerLocator.discover(root: root)
        #expect(discovery.customers.map(\.config.customer) == ["KundeA", "loeti"])
        #expect(discovery.failures.count == 1)
        #expect(discovery.failures.first?.file.path.contains("KundeB") == true)
    }

    @Test("resolves by customer name, folder name, or the nearest config")
    func resolve() throws {
        let root = try makeTree()
        let cwd = URL(fileURLWithPath: "/")
        #expect(try CustomerLocator.resolve(name: "kundea", cwd: cwd, root: root).config.customer == "KundeA")
        #expect(try CustomerLocator.resolve(name: "LOETI", cwd: cwd, root: root).config.customer == "loeti")

        let inside = root.appendingPathComponent("customers/KundeA/repo/src")
        #expect(try CustomerLocator.resolve(name: nil, cwd: inside, root: root).config.customer == "Nested")

        #expect(throws: LWError.self) { try CustomerLocator.resolve(name: "agent-kundeb", cwd: cwd, root: root) }
        #expect(throws: LWError.self) { try CustomerLocator.resolve(name: "KundeZ", cwd: cwd, root: root) }
    }

    @Test("no config above the working directory is an error")
    func noConfig() throws {
        let empty = try Fixtures.temporaryDirectory()
        #expect(throws: LWError.self) { try CustomerLocator.resolve(name: nil, cwd: empty, root: empty) }
    }
}
