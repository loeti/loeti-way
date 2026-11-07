import Foundation

/// Finds `.loeti-way.yaml` files: below the root for `status`, or up from the working
/// directory when no customer is named.
public enum CustomerLocator {
    public struct Failure: Sendable, Equatable {
        public let file: URL
        public let message: String
    }

    public struct Discovery: Sendable, Equatable {
        public var customers: [LoadedCustomer] = []
        public var failures: [Failure] = []
    }

    /// Directories that never contain customer folders but can be huge.
    static let skippedNames: Set<String> = ["node_modules", "Pods", "build", "target", "DerivedData"]

    /// Loads a customer config and the project configs up to `projectDepth` levels below it.
    public static func load(file: URL, projectDepth: Int = 2) throws -> LoadedCustomer {
        let config: CustomerConfig
        do {
            config = try CustomerConfig.parse(try read(file))
        } catch {
            throw LWError("\(file.path): \(error)")
        }
        var customer = LoadedCustomer(config: config, file: file)
        var resolved: [(file: URL, project: LoadedProject)] = []
        for projectFile in findProjects(below: customer.directory, maxDepth: projectDepth) {
            do {
                let project = try ProjectConfig.resolve(try read(projectFile), folder: projectFile.deletingLastPathComponent(), customer: config)
                resolved.append((projectFile, project))
            } catch {
                customer.projectFailures.append(Failure(file: projectFile, message: "\(projectFile.path): \(error)"))
            }
        }
        // Fail closed: folder names that give the same vault name (`x y` and `x-y`) both fail,
        // not just the one found later.
        var counts: [String: Int] = [:]
        for entry in resolved { if let vault = entry.project.vault { counts[vault, default: 0] += 1 } }
        for entry in resolved {
            if let vault = entry.project.vault, counts[vault, default: 0] > 1 {
                let message = "Vault '\(vault)' gehört zu mehreren Projekten (die Ordnernamen ergeben denselben Vault-Namen); Ordner umbenennen"
                customer.projectFailures.append(Failure(file: entry.file, message: "\(entry.file.path): \(message)"))
            } else {
                customer.projects.append(entry.project)
            }
        }
        return customer
    }

    private static func read(_ file: URL) throws -> String {
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw LWError("\(file.path) lässt sich nicht lesen: \(error.localizedDescription)")
        }
    }

    /// Project config files below a customer folder (not in it), without descending further.
    static func findProjects(below directory: URL, maxDepth: Int) -> [URL] {
        var found: [URL] = []
        func visit(_ folder: URL, depth: Int) {
            if depth > 0 {
                let file = folder.appendingPathComponent(ProjectConfig.fileName)
                if FileManager.default.fileExists(atPath: file.path) {
                    found.append(file)
                    return
                }
            }
            guard depth < maxDepth else { return }
            for entry in subdirectories(of: folder) { visit(entry, depth: depth + 1) }
        }
        visit(directory, depth: 0)
        return found
    }

    static func subdirectories(of directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.filter { entry in
            guard !skippedNames.contains(entry.lastPathComponent) else { return false }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    /// Searches `maxDepth` levels below `root` (root/customers/KundeA is depth 2) and doesn't
    /// descend into a folder that has a config.
    public static func discover(root: URL, maxDepth: Int = 3) -> Discovery {
        var result = Discovery()
        walk(root, depth: 0, maxDepth: maxDepth, into: &result)
        result.customers.sort {
            $0.config.customer.localizedCaseInsensitiveCompare($1.config.customer) == .orderedAscending
        }
        return result
    }

    private static func walk(_ directory: URL, depth: Int, maxDepth: Int, into result: inout Discovery) {
        let file = directory.appendingPathComponent(CustomerConfig.fileName)
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                result.customers.append(try load(file: file))
            } catch {
                result.failures.append(Failure(file: file, message: "\(error)"))
            }
            return
        }
        guard depth < maxDepth else { return }
        for entry in subdirectories(of: directory) {
            walk(entry, depth: depth + 1, maxDepth: maxDepth, into: &result)
        }
    }

    /// The nearest config in `start` or one of its parents.
    public static func nearest(from start: URL) -> URL? {
        var directory = start.standardizedFileURL
        while true {
            let file = directory.appendingPathComponent(CustomerConfig.fileName)
            if FileManager.default.fileExists(atPath: file.path) { return file }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path || directory.path == "/" { return nil }
            directory = parent
        }
    }

    /// `name` matches the `customer` field or the folder name, case-insensitively.
    /// Without a name, the nearest config from `cwd` is used.
    public static func resolve(name: String?, cwd: URL, root: URL) throws -> LoadedCustomer {
        guard let name else {
            guard let file = nearest(from: cwd) else {
                throw LWError("Keine \(CustomerConfig.fileName) in \(cwd.path) oder darüber. Kunden angeben oder `lw init` ausführen.")
            }
            return try load(file: file)
        }
        let discovery = discover(root: root)
        let matches = discovery.customers.filter {
            $0.config.customer.caseInsensitiveCompare(name) == .orderedSame
                || $0.directory.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            let paths = matches.map { "  \($0.file.path)" }.joined(separator: "\n")
            throw LWError("'\(name)' ist mehrdeutig:\n\(paths)")
        }
        let broken = discovery.failures.filter {
            $0.file.deletingLastPathComponent().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }
        if let failure = broken.first {
            throw LWError(failure.message)
        }
        throw LWError("Kein Kunde '\(name)' unter \(root.path) gefunden (gesucht: \(CustomerConfig.fileName), bis 3 Ebenen tief).")
    }
}
