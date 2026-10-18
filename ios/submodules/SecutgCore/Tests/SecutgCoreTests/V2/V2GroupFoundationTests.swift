import XCTest
@testable import SecutgCore

/// Ported (reduced set) from Android's `GroupStateTest`/`GroupKeyStoreTest`/`GroupMessagesTest`.
final class V2GroupFoundationTests: XCTestCase {

    // MARK: V2GroupState

    private func genesisState(_ groupId: String) -> V2GroupState {
        let acl = [V2GroupState.AdminAclEntry(deviceId: "dev-1", identityPk: "pk-1")]
        let roster = ["dev-1"]
        let keys = ["dev-1": V2GroupState.DeviceKeys(identityPk: "pk-1", encapsulationPk: "enc-1")]
        return V2GroupState(groupId: groupId, genesisId: "genesis-1", stateHash: "hash-0", epoch: 0, mode: .auto, adminAcl: acl, deviceRoster: roster, deviceKeys: keys, keyCommitment: "kc-0", modeConfirmed: true)
    }

    func testInstallGenesisSucceedsOnceThenRefusesASecondAttempt() {
        let store = V2GroupState.GroupStateStore()
        XCTAssertTrue(store.installGenesis(genesisState("g1")))
        XCTAssertFalse(store.installGenesis(genesisState("g1")))
        XCTAssertNotNil(store.current("g1"))
    }

    func testApplyCommitMovesTheOldCurrentToHistoricalAndInstallsTheNewOne() {
        let store = V2GroupState.GroupStateStore()
        let g0 = genesisState("g1")
        store.installGenesis(g0)
        let g1 = V2GroupState(groupId: "g1", genesisId: g0.genesisId, stateHash: "hash-1", epoch: 1, mode: .auto, adminAcl: g0.adminAcl, deviceRoster: g0.deviceRoster, deviceKeys: g0.deviceKeys, keyCommitment: "kc-1", modeConfirmed: true)
        store.applyCommit(groupId: "g1", newState: g1)
        XCTAssertEqual(store.current("g1")?.stateHash, "hash-1")
        XCTAssertEqual(store.historical("g1").count, 1)
        XCTAssertEqual(store.historical("g1")[0].stateHash, "hash-0")
    }

    func testFindByGenesisAndEpochResolvesTheSpecificGeneration() {
        let store = V2GroupState.GroupStateStore()
        let g0 = genesisState("g1")
        store.installGenesis(g0)
        XCTAssertEqual(store.findByGenesisAndEpoch(groupId: "g1", genesisId: g0.genesisId, epoch: 0)?.stateHash, "hash-0")
        XCTAssertNil(store.findByGenesisAndEpoch(groupId: "g1", genesisId: g0.genesisId, epoch: 5))
    }

    func testAddDeviceGrowsTheRosterButLeavesAnExistingDeviceUntouched() {
        let store = V2GroupState.GroupStateStore()
        store.installGenesis(genesisState("g1"))
        XCTAssertTrue(store.addDevice(groupId: "g1", deviceId: "dev-2", keys: V2GroupState.DeviceKeys(identityPk: "pk-2", encapsulationPk: "enc-2")))
        XCTAssertEqual(store.current("g1")?.deviceRoster.count, 2)
        XCTAssertFalse(store.addDevice(groupId: "g1", deviceId: "dev-2", keys: V2GroupState.DeviceKeys(identityPk: "pk-other", encapsulationPk: "enc-other")))
        XCTAssertEqual(store.current("g1")?.deviceKeys["dev-2"]?.identityPk, "pk-2")
    }

    func testComputeKeyCommitmentIsDeterministicAndBindsEpoch() {
        let genesisId = Base64Url.encode(V2Suite.randomBytes(32))
        var master = [UInt8](repeating: 0, count: 32)
        master[0] = 7
        let a = V2GroupState.computeKeyCommitment(genesisIdB64: genesisId, epoch: 3, master: master)
        let b = V2GroupState.computeKeyCommitment(genesisIdB64: genesisId, epoch: 3, master: master)
        XCTAssertEqual(a, b)
        let differentEpoch = V2GroupState.computeKeyCommitment(genesisIdB64: genesisId, epoch: 4, master: master)
        XCTAssertNotEqual(a, differentEpoch)
    }

    // MARK: V2GroupKeyStore

    func testKeyStoreSetThenGetRoundTripsByGroupAndStateHash() {
        let store = V2GroupKeyStore()
        store.set(V2GroupKeyStore.KeyRecord(groupId: "g1", stateHash: "h0", epoch: 0, status: .current, master: [1, 2, 3]))
        let r = store.get("g1", "h0")
        XCTAssertEqual(r?.status, .current)
        XCTAssertEqual(r?.epoch, 0)
    }

    func testKeyStoreMissingReturnsOnlyRecordsMarkedMissing() {
        let store = V2GroupKeyStore()
        store.set(V2GroupKeyStore.KeyRecord(groupId: "g1", stateHash: "h0", epoch: 0, status: .missing, master: nil))
        store.set(V2GroupKeyStore.KeyRecord(groupId: "g1", stateHash: "h1", epoch: 1, status: .current, master: [1]))
        XCTAssertEqual(store.missing("g1").count, 1)
        XCTAssertEqual(store.missing("g1")[0].stateHash, "h0")
    }

    // MARK: V2GroupMessages

    private func ed() -> V2Suite.KeyPair {
        return V2Suite.generateEd25519()
    }

    private func deviceId(_ identity: V2Suite.KeyPair) -> String {
        return Base64Url.encode(V2Suite.sha256(identity.publicKey))
    }

    private func params(_ actor: V2Suite.KeyPair, groupId: String = "g1", actorUser: String = "100") -> V2GroupMessages.EnvelopeParams {
        return V2GroupMessages.EnvelopeParams(eventId: V2Envelope.randomId(), groupId: groupId, actorUser: actorUser, actorIdentityPk: actor.publicKey, actorIdentitySk: actor.secretKey, createdMs: "1000", expiresMs: "2000")
    }

    func testGenesisRoundTripsThroughBuildAndParse() {
        let identity = ed()
        let enc = V2Suite.generateX25519()
        let acl = [V2GroupMessages.AdminAclEntry(deviceId: deviceId(identity), identityPk: Base64Url.encode(identity.publicKey), encapsulationPk: Base64Url.encode(enc.publicKey))]
        let genesisId = Base64Url.encode(V2Suite.randomBytes(32))
        let keyCommitment = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("kc")))
        let wire = V2GroupMessages.buildGenesis(params(identity), V2GroupMessages.GenesisBody(genesisId: genesisId, mode: .auto, adminAcl: acl, keyCommitment: keyCommitment))
        XCTAssertNotNil(wire)
        let parsed = V2GroupMessages.parseGenesis(wire!)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.body.genesisId, genesisId)
        XCTAssertEqual(parsed!.body.mode, .auto)
        XCTAssertTrue(V2GroupMessages.verifyTyped(parsed!.envelope, identityPkB64: Base64Url.encode(identity.publicKey)))
    }

    func testCommitWithAddDeviceCarriesNewDeviceKeys() {
        let identity = ed()
        let newDeviceIdentity = ed()
        let newDeviceEnc = V2Suite.generateX25519()
        let acl = [V2GroupMessages.AdminAclEntry(deviceId: deviceId(identity), identityPk: Base64Url.encode(identity.publicKey), encapsulationPk: Base64Url.encode(V2Suite.generateX25519().publicKey))]
        let roster = [deviceId(identity), deviceId(newDeviceIdentity)]
        let parentHash = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("parent")))
        let keyCommitment = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("kc")))
        let newDevice = V2GroupMessages.NewDevice(deviceId: deviceId(newDeviceIdentity), identityPk: Base64Url.encode(newDeviceIdentity.publicKey), encapsulationPk: Base64Url.encode(newDeviceEnc.publicKey))
        let wire = V2GroupMessages.buildCommit(params(identity), V2GroupMessages.CommitBody(parentHash: parentHash, epoch: "1", mode: .auto, adminAcl: acl, deviceRoster: roster, keyCommitment: keyCommitment, reason: "add_device", master: nil, newDevice: newDevice))
        XCTAssertNotNil(wire)
        let parsed = V2GroupMessages.parseCommit(wire!)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.body.reason, "add_device")
        XCTAssertEqual(parsed!.body.newDevice?.deviceId, deviceId(newDeviceIdentity))
    }

    func testCommitRejectsAStrayNewDeviceWhenReasonIsNotAddDevice() {
        let identity = ed()
        let acl = [V2GroupMessages.AdminAclEntry(deviceId: deviceId(identity), identityPk: Base64Url.encode(identity.publicKey), encapsulationPk: Base64Url.encode(V2Suite.generateX25519().publicKey))]
        let roster = [deviceId(identity)]
        let parentHash = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("parent")))
        let keyCommitment = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("kc")))
        let stray = V2GroupMessages.NewDevice(deviceId: deviceId(ed()), identityPk: Base64Url.encode(ed().publicKey), encapsulationPk: Base64Url.encode(V2Suite.generateX25519().publicKey))
        let wire = V2GroupMessages.buildCommit(params(identity), V2GroupMessages.CommitBody(parentHash: parentHash, epoch: "1", mode: .auto, adminAcl: acl, deviceRoster: roster, keyCommitment: keyCommitment, reason: "rotate", master: nil, newDevice: stray))
        XCTAssertNotNil(wire)
        XCTAssertNil(V2GroupMessages.parseCommit(wire!))
    }

    func testCommitEpochMustBeAtLeastOneNeverZero() {
        let identity = ed()
        let acl = [V2GroupMessages.AdminAclEntry(deviceId: deviceId(identity), identityPk: Base64Url.encode(identity.publicKey), encapsulationPk: Base64Url.encode(V2Suite.generateX25519().publicKey))]
        let roster = [deviceId(identity)]
        let parentHash = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("parent")))
        let keyCommitment = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("kc")))
        let wire = V2GroupMessages.buildCommit(params(identity), V2GroupMessages.CommitBody(parentHash: parentHash, epoch: "0", mode: .auto, adminAcl: acl, deviceRoster: roster, keyCommitment: keyCommitment, reason: "rotate", master: nil, newDevice: nil))
        XCTAssertNotNil(wire)
        XCTAssertNil(V2GroupMessages.parseCommit(wire!))
    }

    func testJoinRequestPermitAndWelcomeRoundTrip() {
        let identity = ed()
        let enc = V2Suite.generateX25519()
        let stateHash = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("state")))

        let joinWire = V2GroupMessages.buildJoinRequest(params(identity, actorUser: "200"), V2GroupMessages.JoinRequestBody(stateHash: stateHash, identityPk: Base64Url.encode(identity.publicKey), encapsulationPk: Base64Url.encode(enc.publicKey), requestNonce: Base64Url.encode(V2Suite.randomBytes(32))))
        XCTAssertNotNil(joinWire)
        XCTAssertNotNil(V2GroupMessages.parseJoinRequest(joinWire!))

        let permitId = Base64Url.encode(V2Suite.randomBytes(32))
        let permitWire = V2GroupMessages.buildPermit(params(identity), V2GroupMessages.PermitBody(stateHash: stateHash, recipientUser: "200", deviceId: deviceId(identity), signPk: Base64Url.encode(identity.publicKey), rights: "read_write", permitId: permitId))
        XCTAssertNotNil(permitWire)
        let parsedPermit = V2GroupMessages.parsePermit(permitWire!)
        XCTAssertNotNil(parsedPermit)
        XCTAssertEqual(parsedPermit!.body.rights, "read_write")

        let sealed = V2Suite.sealFor(recipientX25519Pk: enc.publicKey, bytes: V2Suite.utf8("master-bytes-placeholder"))
        let welcomeWire = V2GroupMessages.buildWelcome(params(identity), V2GroupMessages.WelcomeBody(stateHash: stateHash, permitHash: Base64Url.encode(V2GroupMessages.hashWire(permitWire!)), recipientDevice: deviceId(identity), sealed: Base64Url.encode(sealed)))
        XCTAssertNotNil(welcomeWire)
        XCTAssertNotNil(V2GroupMessages.parseWelcome(welcomeWire!))
    }
}
