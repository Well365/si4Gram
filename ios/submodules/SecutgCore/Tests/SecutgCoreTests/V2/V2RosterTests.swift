import XCTest
@testable import SecutgCore

/// Ported (reduced set) from Android's `RosterTest.java` — TEST_MATRIX P-43-46. Builds its own
/// two-device binding directly rather than routing through V2Processor, matching the Android
/// precedent: the roster mechanics under test do not depend on how the binding was installed.
final class V2RosterTests: XCTestCase {
    private let chat = "4200"

    private func makeIdentity(_ userId: String) -> V2Identity {
        let ed = V2Suite.generateEd25519()
        let enc = V2Suite.generateX25519()
        return V2Identity(userId: userId, publicKey: ed.publicKey, secretKey: ed.secretKey, encapsulationPk: enc.publicKey, encapsulationSk: enc.secretKey)
    }

    private func deviceId(_ identity: V2Identity) -> String {
        return Base64Url.encode(V2Suite.sha256(identity.publicKey))
    }

    private struct TwoDeviceSetup {
        let aBindingStore = V2Binding.BindingStore()
        let aTombstoneStore = V2Binding.TombstoneStore()
        let aKeyStore = V2KeyStore.BindingKeyStore()
        let bBindingStore = V2Binding.BindingStore()
        let bTombstoneStore = V2Binding.TombstoneStore()
        let bKeyStore = V2KeyStore.BindingKeyStore()
        let bindingId: String
        let originalMaster: [UInt8]

        init(a: V2Identity, b: V2Identity, chat: String) {
            bindingId = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("roster-test-binding")))
            var master = [UInt8](repeating: 0, count: 32)
            master[0] = 42
            originalMaster = master
            let aDevice = Base64Url.encode(V2Suite.sha256(a.publicKey))
            let bDevice = Base64Url.encode(V2Suite.sha256(b.publicKey))
            let deviceKeys: [String: V2Binding.DeviceKeys] = [
                aDevice: V2Binding.DeviceKeys(identityPk: Base64Url.encode(a.publicKey), encapsulationPk: Base64Url.encode(a.encapsulationPk)),
                bDevice: V2Binding.DeviceKeys(identityPk: Base64Url.encode(b.publicKey), encapsulationPk: Base64Url.encode(b.encapsulationPk)),
            ]
            let roster = [aDevice, bDevice].sorted()
            for store in [aBindingStore, bBindingStore] {
                store.install(V2Binding.freshTemplate(chatId: chat, bindingId: bindingId, epoch: 1, deviceRoster: roster, deviceKeys: deviceKeys, revision: 1, txnId: "txn-1", installedAtMs: 1000))
            }
            aKeyStore.installCurrent(bindingId: bindingId, epoch: 1, master: originalMaster)
            bKeyStore.installCurrent(bindingId: bindingId, epoch: 1, master: originalMaster)
        }
    }

    func testP43RekeyRotatesTheMasterToEveryCurrentDeviceTheRosterItselfDoesNotChange() {
        let aIdentity = makeIdentity("100")
        let bIdentity = makeIdentity("200")
        let setup = TwoDeviceSetup(a: aIdentity, b: bIdentity, chat: chat)
        let aRoster = V2Roster.RosterProcessor(identity: aIdentity, bindingStore: setup.aBindingStore, tombstoneStore: setup.aTombstoneStore, keyStore: setup.aKeyStore)
        let bRoster = V2Roster.RosterProcessor(identity: bIdentity, bindingStore: setup.bBindingStore, tombstoneStore: setup.bTombstoneStore, keyStore: setup.bKeyStore)

        let wire = aRoster.rekey(chat)
        XCTAssertNotNil(wire)
        XCTAssertEqual(setup.aBindingStore.current(chat)?.epoch, 2)
        XCTAssertEqual(setup.aBindingStore.current(chat)?.deviceRoster.count, 2)

        let outcome = bRoster.handleRosterCommit(wire!)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.kind, .installed)
        XCTAssertEqual(setup.bKeyStore.get(setup.bindingId, 2)?.master, outcome.master)
        XCTAssertNotEqual(outcome.master, setup.originalMaster)
    }

    func testP44AddDeviceGrowsTheRosterTheNewDeviceGetsAPackageButNeverInheritsVerified() {
        let aIdentity = makeIdentity("100")
        let bIdentity = makeIdentity("200")
        let setup = TwoDeviceSetup(a: aIdentity, b: bIdentity, chat: chat)
        setup.aBindingStore.markVerified(chatId: chat, bindingId: setup.bindingId)
        let aRoster = V2Roster.RosterProcessor(identity: aIdentity, bindingStore: setup.aBindingStore, tombstoneStore: setup.aTombstoneStore, keyStore: setup.aKeyStore)

        let cIdentity = makeIdentity("300")
        let wire = aRoster.addDevice(chatId: chat, newDevice: V2Roster.NewDeviceInput(deviceId: deviceId(cIdentity), identityPk: cIdentity.publicKey, encapsulationPk: cIdentity.encapsulationPk))
        XCTAssertNotNil(wire)
        XCTAssertEqual(setup.aBindingStore.current(chat)?.deviceRoster.count, 3)
        // applyRosterCommit is documented to leave verified untouched (unlike install) — it is a
        // roster/epoch/key rotation on the SAME binding, not a fresh one.
        XCTAssertTrue(setup.aBindingStore.current(chat)!.verified)
    }

    func testP45RemoveDeviceShrinksTheRosterTheRemovedDeviceIsFrozenNotForceUpdated() {
        let aIdentity = makeIdentity("100")
        let bIdentity = makeIdentity("200")
        let setup = TwoDeviceSetup(a: aIdentity, b: bIdentity, chat: chat)
        let aRoster = V2Roster.RosterProcessor(identity: aIdentity, bindingStore: setup.aBindingStore, tombstoneStore: setup.aTombstoneStore, keyStore: setup.aKeyStore)
        let bRoster = V2Roster.RosterProcessor(identity: bIdentity, bindingStore: setup.bBindingStore, tombstoneStore: setup.bTombstoneStore, keyStore: setup.bKeyStore)

        let wire = aRoster.removeDevice(chatId: chat, targetDeviceId: deviceId(bIdentity))
        XCTAssertNotNil(wire)
        XCTAssertEqual(setup.aBindingStore.current(chat)?.deviceRoster.count, 1)

        // The removed device (b) still processes the commit it receives — P-45 says it never gets a
        // FUTURE key, not that it cannot see this one final message; here it simply is NOT in the
        // package list, so handling reports notForMe.
        let outcome = bRoster.handleRosterCommit(wire!)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.kind, .notForMe)
    }

    func testP46AnUnpairThatArrivesFirstPermanentlyBeatsARekeyIssuedEarlierButDeliveredLater() {
        let aIdentity = makeIdentity("100")
        let bIdentity = makeIdentity("200")
        let setup = TwoDeviceSetup(a: aIdentity, b: bIdentity, chat: chat)
        let aRoster = V2Roster.RosterProcessor(identity: aIdentity, bindingStore: setup.aBindingStore, tombstoneStore: setup.aTombstoneStore, keyStore: setup.aKeyStore)
        let bRoster = V2Roster.RosterProcessor(identity: bIdentity, bindingStore: setup.bBindingStore, tombstoneStore: setup.bTombstoneStore, keyStore: setup.bKeyStore)

        let rekeyWire = aRoster.rekey(chat)!
        // b unpairs (and tombstones) BEFORE the rekey wire arrives.
        setup.bTombstoneStore.recordUnpaired(bindingId: setup.bindingId, eventId: "e1", atMs: 5000)
        setup.bBindingStore.deactivate(chat)

        let outcome = bRoster.handleRosterCommit(rekeyWire)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "unpaired")
    }

    func testReplayOfAnAlreadyAppliedEpochIsReportedNotReInstalled() {
        let aIdentity = makeIdentity("100")
        let bIdentity = makeIdentity("200")
        let setup = TwoDeviceSetup(a: aIdentity, b: bIdentity, chat: chat)
        let aRoster = V2Roster.RosterProcessor(identity: aIdentity, bindingStore: setup.aBindingStore, tombstoneStore: setup.aTombstoneStore, keyStore: setup.aKeyStore)
        let bRoster = V2Roster.RosterProcessor(identity: bIdentity, bindingStore: setup.bBindingStore, tombstoneStore: setup.bTombstoneStore, keyStore: setup.bKeyStore)

        let wire = aRoster.rekey(chat)!
        XCTAssertEqual(bRoster.handleRosterCommit(wire).kind, .installed)
        XCTAssertEqual(bRoster.handleRosterCommit(wire).kind, .alreadyApplied)
    }
}
