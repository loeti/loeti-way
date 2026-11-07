import Foundation

public enum AccessAction: Equatable, Sendable, CustomStringConvertible {
    case grant(vault: String, role: VaultRole)
    case revoke(vault: String, shareID: String, role: String)

    public var description: String {
        switch self {
        case let .grant(vault, role): "+ Vault '\(vault)' als \(role.rawValue) freigeben"
        case let .revoke(vault, _, role): "- Vault '\(vault)' (\(role)) entziehen"
        }
    }
}

/// Difference between the vaults in the config and the agent's actual grants.
/// Only whole-vault grants are managed; item and folder grants are reported, never touched.
public struct AccessPlan: Equatable, Sendable {
    public var actions: [AccessAction]
    public var notes: [String]

    public init(actions: [AccessAction] = [], notes: [String] = []) {
        self.actions = actions
        self.notes = notes
    }

    public var isEmpty: Bool { actions.isEmpty }

    /// `allowed` says which vault names this agent may have at all; the host agent passes its
    /// token vault, customer agents keep the default (`agent-…`).
    public static func make(desired: [VaultGrant], actual: [AccessGrant], allowed: (String) -> Bool = VaultNaming.isAgentVault) -> AccessPlan {
        var plan = AccessPlan()
        let vaultGrants = actual.filter { $0.target == .vault }

        for wanted in desired {
            let existing = vaultGrants.filter { $0.name == wanted.name }
            if existing.count == 1, existing[0].role == wanted.role.rawValue { continue }
            // A role can't be changed in place: revoke, then grant again.
            for grant in existing {
                plan.actions.append(.revoke(vault: grant.name, shareID: grant.shareID, role: grant.role))
            }
            plan.actions.append(.grant(vault: wanted.name, role: wanted.role))
        }

        let wantedNames = Set(desired.map(\.name))
        for grant in vaultGrants where !wantedNames.contains(grant.name) {
            plan.actions.append(.revoke(vault: grant.name, shareID: grant.shareID, role: grant.role))
        }

        for grant in vaultGrants where !allowed(grant.name) {
            plan.notes.append("Vault '\(grant.name)' war freigegeben, gehört aber nicht zu diesem Agent. lw entzieht ihn; mit lw audit prüfen, was der Agent gelesen hat")
        }
        for grant in actual where grant.target != .vault {
            plan.notes.append("\(grant.target.rawValue) '\(grant.name)' (\(grant.role)) steht nicht in der Konfiguration; lw lässt den Zugriff unverändert")
        }
        return plan
    }
}
