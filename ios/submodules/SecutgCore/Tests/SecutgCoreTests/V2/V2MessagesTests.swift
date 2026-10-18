import XCTest
@testable import SecutgCore

/// Ported (reduced set) from Android's `MessagesTest.java` / the Web reference's `messages.test.ts`.
final class V2MessagesTests: XCTestCase {

    private func identity() -> V2Suite.KeyPair {
        return V2Suite.generateEd25519()
    }

    private func params(_ actor: V2Suite.KeyPair, txnId: String? = nil) -> V2Messages.EnvelopeParams {
        return V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: txnId, chatId: "4200", actorUser: "100",
            actorIdentityPk: actor.publicKey, actorIdentitySk: actor.secretKey, parentBinding: nil,
            createdMs: "1000", expiresMs: "2000"
        )
    }

    func testInviteRoundTripsThroughBuildAndParseAndVerifies() {
        let actor = identity()
        let ephemeral = V2Suite.generateX25519()
        let encap = V2Suite.generateX25519()
        let wire = V2Messages.buildInvite(params(actor), V2Messages.InviteBody(
            intent: "new", identityPk: Base64Url.encode(actor.publicKey), ephemeralPk: Base64Url.encode(ephemeral.publicKey),
            encapsulationPk: Base64Url.encode(encap.publicKey), targetUser: "200", challenge: Base64Url.encode(V2Suite.randomBytes(16))
        ))
        XCTAssertNotNil(wire)
        let parsed = V2Messages.parseInvite(wire!)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.body.targetUser, "200")
        XCTAssertTrue(V2Messages.verifyTyped(parsed!.envelope, identityPkB64: Base64Url.encode(actor.publicKey)))
    }

    func testInviteRejectsAnInvalidIntent() {
        let actor = identity()
        let ephemeral = V2Suite.generateX25519()
        let encap = V2Suite.generateX25519()
        // Build a well-formed wire, then hand-craft one with a bad "intent" by re-signing raw SJ.
        let body: V2SJValue = .object([
            "intent": "bogus", "identity_pk": .string(Base64Url.encode(actor.publicKey)),
            "ephemeral_pk": .string(Base64Url.encode(ephemeral.publicKey)), "encapsulation_pk": .string(Base64Url.encode(encap.publicKey)),
            "target_user": "200", "challenge": .string(Base64Url.encode(V2Suite.randomBytes(16))),
        ])
        let envelope = V2Envelope.unsigned(
            type: "INVITE", eventId: V2Envelope.randomId(), txnId: nil, chatId: "4200", actorUser: "100",
            actorDevice: Base64Url.encode(V2Suite.sha256(actor.publicKey)), parentBinding: nil, createdMs: "1000", expiresMs: "2000", body: body
        )
        let wire = V2Envelope.build(prefix: V2Messages.prefix, domain: V2Messages.domain, envelope: envelope, secretKey: actor.secretKey)!
        XCTAssertNil(V2Messages.parseInvite(wire))
    }

    func testAcceptRoundTripsAndVerifies() {
        let actor = identity()
        let ephemeral = V2Suite.generateX25519()
        let encap = V2Suite.generateX25519()
        let wire = V2Messages.buildAccept(params(actor, txnId: V2Envelope.randomId()), V2Messages.AcceptBody(
            inviteHash: Base64Url.encode(V2Suite.sha256(V2Suite.utf8("invite"))), identityPk: Base64Url.encode(actor.publicKey),
            ephemeralPk: Base64Url.encode(ephemeral.publicKey), encapsulationPk: Base64Url.encode(encap.publicKey),
            challenge: Base64Url.encode(V2Suite.randomBytes(16))
        ))
        let parsed = V2Messages.parseAccept(wire!)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(V2Messages.verifyTyped(parsed!.envelope, identityPkB64: Base64Url.encode(actor.publicKey)))
    }

    func testATamperedSignatureFailsVerification() {
        let actor = identity()
        let wire = V2Messages.buildCancel(params(actor, txnId: V2Envelope.randomId()), V2Messages.CancelBody(targetTxnId: "t1", reason: "user_cancelled"))!
        let flipped = wire.hasSuffix("A") ? String(wire.dropLast()) + "B" : String(wire.dropLast()) + "A"
        if let parsed = V2Messages.parseCancel(flipped) {
            XCTAssertFalse(V2Messages.verifyTyped(parsed.envelope, identityPkB64: Base64Url.encode(actor.publicKey)))
        }
    }

    func testRosterCommitAddDeviceRoundTripsWithNewDeviceKeys() {
        let actor = identity()
        let newDeviceIdentity = identity()
        let newDeviceEncap = V2Suite.generateX25519()
        let newDeviceId = Base64Url.encode(V2Suite.sha256(newDeviceIdentity.publicKey))
        let wire = V2Messages.buildRosterCommit(params(actor), V2Messages.RosterCommitBody(
            reason: "add_device", bindingId: Base64Url.encode(V2Suite.sha256(V2Suite.utf8("binding"))), epoch: "2",
            deviceRoster: [Base64Url.encode(V2Suite.sha256(actor.publicKey)), newDeviceId],
            packages: [V2Messages.DevicePackage(deviceId: newDeviceId, pkg: Base64Url.encode(V2Suite.randomBytes(48)))],
            newDevice: V2Messages.NewDevice(deviceId: newDeviceId, identityPk: Base64Url.encode(newDeviceIdentity.publicKey), encapsulationPk: Base64Url.encode(newDeviceEncap.publicKey))
        ))
        XCTAssertNotNil(wire)
        let parsed = V2Messages.parseRosterCommit(wire!)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.body.reason, "add_device")
        XCTAssertNotNil(parsed!.body.newDevice)
        XCTAssertEqual(parsed!.body.newDevice?.deviceId, newDeviceId)
    }

    func testRosterCommitRejectsAStrayNewDeviceWhenReasonIsNotAddDevice() {
        let actor = identity()
        let deviceId = Base64Url.encode(V2Suite.sha256(actor.publicKey))
        let strayIdentity = identity()
        let strayEncap = V2Suite.generateX25519()
        let strayDeviceId = Base64Url.encode(V2Suite.sha256(strayIdentity.publicKey))
        let wire = V2Messages.buildRosterCommit(params(actor), V2Messages.RosterCommitBody(
            reason: "rekey", bindingId: Base64Url.encode(V2Suite.sha256(V2Suite.utf8("binding"))), epoch: "2",
            deviceRoster: [deviceId], packages: [],
            newDevice: V2Messages.NewDevice(deviceId: strayDeviceId, identityPk: Base64Url.encode(strayIdentity.publicKey), encapsulationPk: Base64Url.encode(strayEncap.publicKey))
        ))
        XCTAssertNotNil(wire)
        XCTAssertNil(V2Messages.parseRosterCommit(wire!))
    }

    func testHashWireIsDeterministic() {
        XCTAssertEqual(V2Messages.hashWire("abc"), V2Messages.hashWire("abc"))
        XCTAssertNotEqual(V2Messages.hashWire("abc"), V2Messages.hashWire("abd"))
    }
}
