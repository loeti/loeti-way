import Testing
@testable import LoetiWayKit

@Suite("Access plan")
struct AccessPlanTests {
    let desired = [VaultGrant(name: "KundeA"), VaultGrant(name: "KundeA Infra", role: .editor)]

    @Test("a new agent gets every vault")
    func newAgent() {
        let plan = AccessPlan.make(desired: desired, actual: [])
        #expect(plan.actions == [.grant(vault: "KundeA", role: .viewer), .grant(vault: "KundeA Infra", role: .editor)])
    }

    @Test("matching grants need nothing")
    func upToDate() {
        let actual = [
            AccessGrant(target: .vault, shareID: "s1", name: "KundeA", role: "viewer"),
            AccessGrant(target: .vault, shareID: "s2", name: "KundeA Infra", role: "editor"),
        ]
        #expect(AccessPlan.make(desired: desired, actual: actual).isEmpty)
    }

    @Test("a changed role is revoked and granted again, extra vaults are revoked")
    func drift() {
        let actual = [
            AccessGrant(target: .vault, shareID: "s1", name: "KundeA", role: "viewer"),
            AccessGrant(target: .vault, shareID: "s2", name: "KundeA Infra", role: "viewer"),
            AccessGrant(target: .vault, shareID: "s3", name: "KundeB", role: "viewer"),
        ]
        let plan = AccessPlan.make(desired: desired, actual: actual)
        #expect(plan.actions == [
            .revoke(vault: "KundeA Infra", shareID: "s2", role: "viewer"),
            .grant(vault: "KundeA Infra", role: .editor),
            .revoke(vault: "KundeB", shareID: "s3", role: "viewer"),
        ])
    }

    @Test("item and folder grants are reported, not touched")
    func unmanaged() {
        let actual = [
            AccessGrant(target: .vault, shareID: "s1", name: "KundeA", role: "viewer"),
            AccessGrant(target: .vault, shareID: "s2", name: "KundeA Infra", role: "editor"),
            AccessGrant(target: .item, shareID: "s9", name: "DB password", role: "viewer"),
        ]
        let plan = AccessPlan.make(desired: desired, actual: actual)
        #expect(plan.isEmpty)
        #expect(plan.notes.count == 1)
        #expect(plan.notes[0].contains("DB password"))
    }
}
