import Foundation
import Yams

/// `~/.config/loeti-way/config.yaml`. Every key is optional.
///
/// ```yaml
/// root: /Volumes/Code          # where `lw status` looks for customers
/// token_vault: lw-tokens       # Proton vault for all tokens; must start with lw-
/// host_agent: lw-host          # the only agent with access to the token vault (viewer)
/// warn_days: 14                # warn this many days before a token expires
/// ```
///
/// Next to the file: `host-token`, the host agent's token (mode 0600). Logins of pass-cli live
/// in `~/.cache/loeti-way/sessions` (`$XDG_CACHE_HOME`).
public struct GlobalConfig: Equatable, Sendable {
    public static let defaultRoot = "/Volumes/Code"
    public static let defaultTokenVault = "lw-tokens"
    public static let defaultHostAgent = "lw-host"

    public var root: URL
    public var tokenVault: String
    public var hostAgent: String
    public var warnDays: Int
    public var hostTokenFile: URL
    public var sessionsDirectory: URL

    public init(root: URL, tokenVault: String = GlobalConfig.defaultTokenVault, hostAgent: String = GlobalConfig.defaultHostAgent,
                warnDays: Int = 14, environment: [String: String] = [:]) {
        self.root = root
        self.tokenVault = tokenVault
        self.hostAgent = hostAgent
        self.warnDays = warnDays
        self.hostTokenFile = Self.fileURL(environment: environment).deletingLastPathComponent().appendingPathComponent("host-token")
        self.sessionsDirectory = Self.cacheURL(environment: environment).appendingPathComponent("sessions", isDirectory: true)
    }

    private struct File: Decodable {
        var root: String?
        var tokenVault: String?
        var hostAgent: String?
        var warnDays: Int?

        enum CodingKeys: String, CodingKey {
            case root
            case tokenVault = "token_vault"
            case hostAgent = "host_agent"
            case warnDays = "warn_days"
        }
    }

    static func home(_ environment: [String: String]) -> URL {
        URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
    }

    static func cacheURL(environment: [String: String]) -> URL {
        let base = environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home(environment).appendingPathComponent(".cache")
        return base.appendingPathComponent("loeti-way", isDirectory: true)
    }

    public static func fileURL(environment: [String: String]) -> URL {
        let base = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home(environment).appendingPathComponent(".config")
        return base.appendingPathComponent("loeti-way").appendingPathComponent("config.yaml")
    }

    /// Order: environment (`LW_ROOT`, `LW_TOKEN_VAULT`) → config file → defaults.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> GlobalConfig {
        let url = fileURL(environment: environment)
        var file = File()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                file = try YAMLDecoder().decode(File.self, from: text)
            } catch {
                throw LWError("\(url.path): \(error)")
            }
        }
        let rootPath = environment["LW_ROOT"] ?? file.root ?? defaultRoot
        return GlobalConfig(
            root: URL(fileURLWithPath: expandTilde(rootPath, environment: environment)),
            tokenVault: environment["LW_TOKEN_VAULT"] ?? file.tokenVault ?? defaultTokenVault,
            hostAgent: file.hostAgent ?? defaultHostAgent,
            warnDays: file.warnDays ?? 14,
            environment: environment
        )
    }

    /// Settings can also come from options after `load`, so commands check them here.
    public func validate() throws {
        if let problem = VaultNaming.problem(tokenVault: tokenVault) {
            throw LWError(problem)
        }
        if hostAgent.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LWError("'host_agent' ist leer")
        }
    }

    static func expandTilde(_ path: String, environment: [String: String]) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return home + path.dropFirst()
    }
}
