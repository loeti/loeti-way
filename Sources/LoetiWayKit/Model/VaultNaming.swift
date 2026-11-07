import Foundation

/// Reserved vault name prefixes. `agent-` vaults are the only ones an agent may get, `lw-` vaults
/// (the token vault) belong to the user's account only. Every other vault is private and lw
/// never grants it.
///
/// After the prefix, a name is lowercase ASCII words joined by dashes, so it needs no quoting
/// in the shell or in `pass://` references.
public enum VaultNaming {
    public static let agentPrefix = "agent-"
    public static let lwPrefix = "lw-"

    /// Default vault for a customer: `agent-<customer slug>`.
    public static func agentVault(customer: String) -> String {
        agentPrefix + Slug.make(customer)
    }

    public static func isAgentVault(_ name: String) -> Bool {
        hasPrefix(agentPrefix, name)
    }

    public static func isLWVault(_ name: String) -> Bool {
        hasPrefix(lwPrefix, name)
    }

    /// Problem with a vault in `proton.vaults`, nil if it may be granted.
    static func problem(agentVault name: String) -> String? {
        if isAgentVault(name) { return nil }
        return "Vault '\(name)' kann keinem Agent freigegeben werden: Vaults für Agents heissen \(agentPrefix)<name>, z.B. \(agentPrefix)\(suggestion(for: name))"
    }

    /// Problem with the configured token vault, nil if it is fine.
    public static func problem(tokenVault name: String) -> String? {
        if isLWVault(name) { return nil }
        return "Token-Vault '\(name)' muss \(lwPrefix)<name> heissen, z.B. \(lwPrefix)tokens. Vaults ohne \(lwPrefix) sind für Agents oder privat."
    }

    private static func hasPrefix(_ prefix: String, _ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let rest = String(name.dropFirst(prefix.count))
        return !rest.isEmpty && Slug.make(rest) == rest
    }

    private static func suggestion(for name: String) -> String {
        var slug = Slug.make(name)
        if slug.hasPrefix(agentPrefix) { slug.removeFirst(agentPrefix.count) }
        if slug == "agent" { slug = "" }
        return slug.isEmpty ? "kunde" : slug
    }
}
