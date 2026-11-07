import Foundation

/// `owner/name` of a repository on github.com.
public struct GitHubRepository: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var owner: String
    public var name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var description: String { "\(owner)/\(name)" }

    /// `git@github.com:o/r.git`, `ssh://git@github.com/o/r`, `https://github.com/o/r.git`, …
    public init?(remote url: String) {
        var rest = url.trimmingCharacters(in: .whitespaces)
        let prefixes = ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/", "git://github.com/"]
        if let prefix = prefixes.first(where: rest.hasPrefix) {
            rest = String(rest.dropFirst(prefix.count))
        } else if let range = rest.range(of: "@github.com/"), rest.hasPrefix("https://") {
            rest = String(rest[range.upperBound...])
        } else {
            return nil
        }
        while rest.hasSuffix("/") { rest.removeLast() }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        let parts = rest.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        (owner, name) = (parts[0], parts[1])
    }
}

/// A git working copy below the root.
public struct GitRepository: Equatable, Sendable {
    public var directory: URL
    /// URL of `origin`, nil without one.
    public var origin: String?

    public var github: GitHubRepository? { origin.flatMap(GitHubRepository.init(remote:)) }

    public init(directory: URL, origin: String?) {
        self.directory = directory
        self.origin = origin
    }

    /// Reads `origin` from the repository's config, also for worktrees (`.git` file).
    public static func open(_ directory: URL) -> GitRepository? {
        let dotGit = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        var gitDir = dotGit
        if !isDirectory.boolValue {
            guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
                return GitRepository(directory: directory, origin: nil)
            }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
            if let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
                let commonPath = common.trimmingCharacters(in: .whitespacesAndNewlines)
                gitDir = commonPath.hasPrefix("/") ? URL(fileURLWithPath: commonPath) : gitDir.appendingPathComponent(commonPath)
            }
        }
        let config = (try? String(contentsOf: gitDir.appendingPathComponent("config"), encoding: .utf8)) ?? ""
        return GitRepository(directory: directory, origin: originURL(inConfig: config))
    }

    static func originURL(inConfig text: String) -> String? {
        var inOrigin = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == #"[remote"origin"]"#
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces) == "url" {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Working copies up to `maxDepth` levels below `directory` (and `directory` itself). Doesn't
    /// descend into a repository, nor into folders `stop` returns true for.
    public static func find(below directory: URL, maxDepth: Int, stop: (URL) -> Bool = { _ in false }) -> [GitRepository] {
        var found: [GitRepository] = []
        func visit(_ folder: URL, depth: Int) {
            if depth > 0 && stop(folder) { return }
            if let repository = open(folder) {
                found.append(repository)
                return
            }
            guard depth < maxDepth else { return }
            for entry in CustomerLocator.subdirectories(of: folder) { visit(entry, depth: depth + 1) }
        }
        visit(directory, depth: 0)
        return found
    }
}

/// What a folder's `.envrc` does, judged by its text.
public enum EnvrcState: Equatable, Sendable {
    case missing
    /// Calls `lw env`.
    case current
    /// Reads tokens with pass-cli itself (lw before `lw env`).
    case outdated
    /// Something else; it only loads tokens if it chains to a parent `.envrc`.
    case own(chainsUp: Bool)

    public static func check(_ directory: URL) -> EnvrcState {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(".envrc"), encoding: .utf8) else {
            return .missing
        }
        if text.contains("lw env") { return .current }
        if text.contains("pass-cli") { return .outdated }
        return .own(chainsUp: text.contains("source_up"))
    }
}
