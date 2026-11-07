import Foundation

/// Keeps one secure note per token in a vault: agent tokens in the token vault (no customer agent
/// may read it), provider tokens in the customer's or project's `agent-` vault.
public struct TokenStore {
    public let pass: PassCLI
    public let vault: String

    public init(pass: PassCLI, vault: String) {
        self.pass = pass
        self.vault = vault
    }

    /// Active items in the vault. Fails with a hint if the vault doesn't exist, so callers can
    /// check this before creating a token they couldn't store.
    public func items() throws -> [VaultItem] {
        do {
            return try pass.listItems(vault: vault).filter(\.isActive)
        } catch {
            throw LWError("\(error)\nGibt es den Vault '\(vault)'? Anlegen mit: pass-cli vault create --name \"\(vault)\"")
        }
    }

    /// Creates the new note first and deletes older notes with the same title afterwards, so
    /// a failure never leaves the vault without a token.
    public func save(title: String, token: String) throws {
        let previous = try items().filter { $0.title == title }
        try pass.createNote(vault: vault, title: title, note: token)
        for item in previous {
            try pass.deleteItem(shareID: item.shareID, itemID: item.id)
        }
    }

    public func read(title: String) throws -> String {
        try pass.readNote(vault: vault, title: title)
    }

    public func reference(title: String) -> String {
        PassCLI.reference(vault: vault, item: title)
    }
}
