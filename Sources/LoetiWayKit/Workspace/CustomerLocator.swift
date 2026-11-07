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

    public static func load(file: URL) throws -> LoadedCustomer {
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw LWError("\(file.path) lässt sich nicht lesen: \(error.localizedDescription)")
        }
        do {
            return LoadedCustomer(config: try CustomerConfig.parse(text), file: file)
        } catch {
            throw LWError("\(file.path): \(error)")
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
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !skippedNames.contains(entry.lastPathComponent) else { continue }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
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
