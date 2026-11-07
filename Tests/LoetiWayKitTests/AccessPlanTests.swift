import Testing
@testable import LoetiWayKit

@Suite("Access plan")
struct AccessPlanTests {
    let desired = [VaultGrant(name: "agent-kundea"), VaultGrant(name: "agent-kundea-infra", role: .editor)]

    @Test("a new agent gets every vault")
    func newAgent() {
        let plan = AccessPlan.make(desired: desired, actual: [])
        #expect(plan.actions == [.grant(vault: "agent-kundea", role: .viewer), .grant(vault: "agent-kundea-infra", role: .editor)])
    }

    @Test("matching grants need nothing")
    func upToDate() {
        let actual = [
            AccessGrant(target: .vault, shareID: "s1", name: "agent-kundea", role: "viewer"),
            AccessGrant(target: .vault, shareID: "s2", name: "agent-kundea-infra", role: "editor"),
        ]
        #expect(AccessPlan.make(desired: desired, actual: actual).isEmpty)
    }

    @Test("a changed role is revoked and granted again, extra vaults are revoked")
    func drift() {
        let actual = [
            AccessGrant(target: .vault, shareID: "s1", name: "agent-kundea", role: "viewer"),
            AccessGrant(target: .vault, shareID: "s2", name: "agent-kundea-infra", role: "viewer"),
            AccessGrant(target: .vault, shareID: "s3", name: "agent-kundeb", role: "viewer"),
        ]
        let plan = AccessPlan.make(desired: desired, actual: actual)
        #expect(plan.actions == [
            .revoke(vault: "agent-kundea-infra", shareID: "s2", role: "viewer"),
            .grant(vault: "agent-kundea-infra", role: .editor),
            .revoke(vault: "agent-kundeb", shareID: "s3", role: "viewer"),
        ])
    }

    @Test("item and folder grants are reported, not touched")
    func unmanaged() {
        let actual = [
            AccessGrant(target: .vault, shareID: "s1", name: "agent-kundea", role: "viewer"),
            AccessGrant(target: .vault, shareID: "s2", name: "agent-kundea-infra", role: "editor"),
            AccessGrant(target: .item, shareID: "s9", name: "DB password", role: "viewer"),
        ]
        let plan = AccessPlan.make(desired: desired, actual: actual)
        #expect(plan.isEmpty)
        #expect(plan.notes.count == 1)
        #expect(plan.notes[0].contains("DB password"))
    }

    @Test("a granted vault outside agent- is revoked and reported")
    func foreignVault() {
        let actual = [
            AccessGrant(target: .vault, shareID: "s1", name: "agent-kundea", role: "viewer"),
            AccessGrant(target: .vault, shareID: "s2", name: "agent-kundea-infra", role: "editor"),
            AccessGrant(target: .vault, shareID: "s3", name: "Persönlich", role: "viewer"),
        ]
        let plan = AccessPlan.make(desired: desired, actual: actual)
        #expect(plan.actions == [.revoke(vault: "Persönlich", shareID: "s3", role: "viewer")])
        #expect(plan.notes.count == 1)
        #expect(plan.notes[0].contains("'Persönlich' heisst nicht agent-"))
    }
}
