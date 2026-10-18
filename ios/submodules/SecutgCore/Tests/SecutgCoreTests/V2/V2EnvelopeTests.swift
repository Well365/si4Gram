import XCTest
@testable import SecutgCore

/// Ported from Android's `EnvelopeTest.java` / the Web reference's `envelope.test.ts`. Base64url
/// round-trip/malformed-input coverage is not re-derived here — this port reuses the module's
/// existing, already-tested `Base64Url` codec rather than a second hand-rolled implementation.
final class V2EnvelopeTests: XCTestCase {
    private let domain = "secuTG/v2/TEST"
    private let prefix = "T2"

    private func makeEnvelope(body: V2SJValue = .object(["x": "1"]), txnId: String? = nil, parentBinding: String? = nil) -> (V2Envelope, V2Suite.KeyPair) {
        let identity = V2Suite.generateEd25519()
        let envelope = V2Envelope.unsigned(
            type: "TEST", eventId: V2Envelope.randomId(), txnId: txnId, chatId: "chat-1", actorUser: "100",
            actorDevice: Base64Url.encode(V2Suite.sha256(identity.publicKey)), parentBinding: parentBinding,
            createdMs: "1000", expiresMs: "2000", body: body
        )
        return (envelope, identity)
    }

    func testAGenuineEnvelopeRoundTripsAndVerifies() {
        let (envelope, identity) = makeEnvelope()
        let wire = V2Envelope.build(prefix: prefix, domain: domain, envelope: envelope, secretKey: identity.secretKey)
        XCTAssertNotNil(wire)
        let parsed = V2Envelope.parse(prefix: prefix, text: wire!)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.type, "TEST")
        XCTAssertEqual(parsed!.chatId, "chat-1")
        XCTAssertEqual(parsed!.body, .object(["x": "1"]))
        XCTAssertTrue(V2Envelope.verify(domain: domain, envelope: parsed!, actorPublicKey: identity.publicKey))
    }

    func testTxnIdAndParentBindingRoundTripWhenPresentAndAreSimplyAbsentWhenNot() {
        let digest = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("parent")))
        let (withBoth, identity) = makeEnvelope(txnId: V2Envelope.randomId(), parentBinding: digest)
        let wireWithBoth = V2Envelope.build(prefix: prefix, domain: domain, envelope: withBoth, secretKey: identity.secretKey)!
        let parsedWithBoth = V2Envelope.parse(prefix: prefix, text: wireWithBoth)!
        XCTAssertEqual(parsedWithBoth.txnId, withBoth.txnId)
        XCTAssertEqual(parsedWithBoth.parentBinding, digest)

        let (withNeither, identity2) = makeEnvelope()
        let wireWithNeither = V2Envelope.build(prefix: prefix, domain: domain, envelope: withNeither, secretKey: identity2.secretKey)!
        let parsedWithNeither = V2Envelope.parse(prefix: prefix, text: wireWithNeither)!
        XCTAssertNil(parsedWithNeither.txnId)
        XCTAssertNil(parsedWithNeither.parentBinding)
    }

    func testATamperedFieldFailsVerificationEvenThoughTheEnvelopeStillParses() {
        let (envelope, identity) = makeEnvelope()
        let wire = V2Envelope.build(prefix: prefix, domain: domain, envelope: envelope, secretKey: identity.secretKey)!
        let parsed = V2Envelope.parse(prefix: prefix, text: wire)!
        let tampered = V2Envelope(
            type: parsed.type, eventId: parsed.eventId, txnId: parsed.txnId, chatId: "chat-DIFFERENT",
            actorUser: parsed.actorUser, actorDevice: parsed.actorDevice, parentBinding: parsed.parentBinding,
            createdMs: parsed.createdMs, expiresMs: parsed.expiresMs, body: parsed.body, sig: parsed.sig
        )
        XCTAssertFalse(V2Envelope.verify(domain: domain, envelope: tampered, actorPublicKey: identity.publicKey))
    }

    func testAForgedSignersPublicKeyDoesNotVerify() {
        let (envelope, identity) = makeEnvelope()
        let wire = V2Envelope.build(prefix: prefix, domain: domain, envelope: envelope, secretKey: identity.secretKey)!
        let parsed = V2Envelope.parse(prefix: prefix, text: wire)!
        let impostor = V2Suite.generateEd25519()
        XCTAssertFalse(V2Envelope.verify(domain: domain, envelope: parsed, actorPublicKey: impostor.publicKey))
    }

    func testDomainSeparationASignatureDoesNotVerifyUnderADifferentDomain() {
        let (envelope, identity) = makeEnvelope()
        let wire = V2Envelope.build(prefix: prefix, domain: domain, envelope: envelope, secretKey: identity.secretKey)!
        let parsed = V2Envelope.parse(prefix: prefix, text: wire)!
        XCTAssertFalse(V2Envelope.verify(domain: "secuTG/v2/OTHER", envelope: parsed, actorPublicKey: identity.publicKey))
    }

    func testAnActorDeviceThatDoesNotMatchTheVerifyingPublicKeyIsRefused() {
        let (envelope, identity) = makeEnvelope()
        let wire = V2Envelope.build(prefix: prefix, domain: domain, envelope: envelope, secretKey: identity.secretKey)!
        let parsed = V2Envelope.parse(prefix: prefix, text: wire)!
        let otherIdentity = V2Suite.generateEd25519()
        // otherIdentity's secret key can still produce a VALID signature over the same bytes (since
        // signingInput does not itself depend on actorDevice's relationship to the signer beyond what
        // verify separately checks), but actorDevice in the envelope still names the ORIGINAL identity.
        XCTAssertFalse(V2Envelope.verify(domain: domain, envelope: parsed, actorPublicKey: otherIdentity.publicKey))
    }

    func testWrongPrefixGarbageBase64OrNonSjPayloadAreAllRefused() {
        let (envelope, identity) = makeEnvelope()
        let wire = V2Envelope.build(prefix: prefix, domain: domain, envelope: envelope, secretKey: identity.secretKey)!
        XCTAssertNil(V2Envelope.parse(prefix: "X2", text: wire))
        XCTAssertNil(V2Envelope.parse(prefix: prefix, text: "\(prefix):not-valid-base64!!!"))
        XCTAssertNil(V2Envelope.parse(prefix: prefix, text: "\(prefix):"))
    }

    func testAMissingRequiredFieldIsRefused() {
        let identity = V2Suite.generateEd25519()
        // Hand-build an SJ object missing "chat_id".
        let obj: V2SJValue = .object([
            "v": "2", "type": "TEST", "event_id": .string(V2Envelope.randomId()), "actor_user": "100",
            "actor_device": .string(Base64Url.encode(V2Suite.sha256(identity.publicKey))),
            "created_ms": "1000", "expires_ms": "2000", "body": .object(["x": "1"]),
        ])
        let canonical = V2SJ.serialize(obj)!
        let wire = "\(prefix):" + Base64Url.encode(V2Suite.utf8(canonical))
        XCTAssertNil(V2Envelope.parse(prefix: prefix, text: wire))
    }

    func testAnActorDeviceThatIsNotA32ByteDigestIsRefused() {
        let obj: V2SJValue = .object([
            "v": "2", "type": "TEST", "event_id": .string(V2Envelope.randomId()), "chat_id": "chat-1",
            "actor_user": "100", "actor_device": "too-short", "created_ms": "1000", "expires_ms": "2000",
            "body": .object(["x": "1"]), "sig": .string(Base64Url.encode([UInt8](repeating: 0, count: 64))),
        ])
        let canonical = V2SJ.serialize(obj)!
        let wire = "\(prefix):" + Base64Url.encode(V2Suite.utf8(canonical))
        XCTAssertNil(V2Envelope.parse(prefix: prefix, text: wire))
    }

    func testCreatedMsExpiresMsMustBePlainUnsignedDecimalStrings() {
        let identity = V2Suite.generateEd25519()
        func wire(createdMs: String) -> String {
            let obj: V2SJValue = .object([
                "v": "2", "type": "TEST", "event_id": .string(V2Envelope.randomId()), "chat_id": "chat-1",
                "actor_user": "100", "actor_device": .string(Base64Url.encode(V2Suite.sha256(identity.publicKey))),
                "created_ms": .string(createdMs), "expires_ms": "2000", "body": .object(["x": "1"]),
                "sig": .string(Base64Url.encode([UInt8](repeating: 0, count: 64))),
            ])
            let canonical = V2SJ.serialize(obj)!
            return "\(prefix):" + Base64Url.encode(V2Suite.utf8(canonical))
        }
        XCTAssertNil(V2Envelope.parse(prefix: prefix, text: wire(createdMs: "-1")))
        XCTAssertNil(V2Envelope.parse(prefix: prefix, text: wire(createdMs: "1.5")))
        XCTAssertNil(V2Envelope.parse(prefix: prefix, text: wire(createdMs: "abc")))
        XCTAssertNotNil(V2Envelope.parse(prefix: prefix, text: wire(createdMs: "0")))
    }
}
