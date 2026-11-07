import Foundation

/// Who is logged in, in one `PROTON_PASS_SESSION_DIR`. Without that variable pass-cli uses a
/// default directory that every process of the macOS user shares; lw never logs in there.
public enum PassSession: Equatable, Sendable, CustomStringConvertible {
    /// The user's own account: full access to every vault.
    case account(username: String?)
    /// An agent's personal access token.
    case token(name: String?)
    case loggedOut

    /// Parses `pass-cli info`, which prints `- Key: value` lines.
    static func parse(info: String) -> PassSession {
        var fields: [String: String] = [:]
        for line in info.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("- "), let colon = text.firstIndex(of: ":") else { continue }
            let key = text[text.index(text.startIndex, offsetBy: 2)..<colon].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value.isEmpty ? nil : value
        }
        if fields.keys.contains("Personal Access Token") {
            return .token(name: fields["Personal Access Token"])
        }
        return .account(username: fields["Username"])
    }

    public var isAccount: Bool {
        if case .account = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case let .account(username?): "angemeldet als \(username) (dein Konto, Zugriff auf alle Vaults)"
        case .account(nil): "angemeldet mit deinem Konto (Zugriff auf alle Vaults)"
        case let .token(name?): "angemeldet mit dem Token von Agent '\(name)'"
        case .token(nil): "angemeldet mit einem Agent-Token"
        case .loggedOut: "nicht angemeldet"
        }
    }

    public func requireAccount() throws {
        switch self {
        case .account: return
        case .token: throw LWError("Mit einem Agent-Token angemeldet, nicht mit deinem Konto. Agents kann nur dein Konto verwalten.")
        case .loggedOut: throw LWError("Nicht mit deinem Konto bei Proton Pass angemeldet.")
        }
    }
}
