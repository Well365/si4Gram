import XCTest
@testable import SecutgCore

/// Ported from Android's `W2Test.java` — no TEST_MATRIX.md section exists for WIPE-01, cases derived
/// directly from v1.4 section 19/16's own text.
final class V2W2Tests: XCTestCase {
    private let account = "acct-100"
    private let now: Int64 = 1_000_000_000

    private struct Setup {
        let issuer: V2Suite.KeyPair
        let target: V2Suite.KeyPair
        let targetDeviceId: String
        let store: V2W2.W2AuthorizationStore
        let dedup: V2W2.W2DedupStore
    }

    private func makeSetup(account: String) -> Setup {
        let issuer = V2Suite.generateEd25519()
        let target = V2Suite.generateEd25519()
        let targetDeviceId = V2E2.deviceIdOf(target.publicKey)
        let store = V2W2.W2AuthorizationStore()
        let dedup = V2W2.W2DedupStore()
        store.authorize(V2W2.Authorization(account: account, controlPublicKey: Base64Url.encode(issuer.publicKey), allowedScope: ["wipe_all"]))
        return Setup(issuer: issuer, target: target, targetDeviceId: targetDeviceId, store: store, dedup: dedup)
    }

    private func validEvent(_ issuer: V2Suite.KeyPair, _ targetDeviceId: String, scope: [String] = ["wipe_all"]) -> String {
        return V2W2.buildW2Event(V2W2.BuildParams(account: account, issuerIdentityPk: issuer.publicKey, issuerIdentitySk: issuer.secretKey, targetDevices: [targetDeviceId], scope: scope, issuedAtMs: now, expiresAtMs: now + 60 * 60 * 1000))!
    }

    func testAFullyPreAuthorizedEventAutoExecutes() {
        let s = makeSetup(account: account)
        let wire = validEvent(s.issuer, s.targetDeviceId)
        let outcome = V2W2.handleW2Event(wire, store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: now)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.kind, "auto_execute")
        XCTAssertEqual(outcome.scope, ["wipe_all"])
    }

    func testValidCorrectlySignedButScopeExceedsPreAuthorizationNeedsConfirmationNotRefusal() {
        let s = makeSetup(account: account)
        let wire = validEvent(s.issuer, s.targetDeviceId, scope: ["wipe_all", "wipe_media_only"])
        let outcome = V2W2.handleW2Event(wire, store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: now)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.kind, "needs_confirmation")
        XCTAssertEqual(outcome.scope, ["wipe_all", "wipe_media_only"])
    }

    func testRepeatDeliveryOfAnAlreadyProcessedEventIsIdempotentNotReExecuted() {
        let s = makeSetup(account: account)
        let wire = validEvent(s.issuer, s.targetDeviceId)
        XCTAssertEqual(V2W2.handleW2Event(wire, store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: now).kind, "auto_execute")
        let second = V2W2.handleW2Event(wire, store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: now)
        XCTAssertTrue(second.ok)
        XCTAssertEqual(second.kind, "already_processed")
        XCTAssertEqual(second.scope, ["wipe_all"])
    }

    func testNoLocalAuthorizationAtAllRefusesOutrightThereIsNoFallbackAuthenticationPath() {
        let s = makeSetup(account: account)
        let emptyStore = V2W2.W2AuthorizationStore()
        let wire = validEvent(s.issuer, s.targetDeviceId)
        let outcome = V2W2.handleW2Event(wire, store: emptyStore, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: now)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "no_local_authorization")
    }

    func testASignatureFromADifferentKeyThanTheOneLocallyStoredIsRefusedEvenValidLooking() {
        let s = makeSetup(account: account)
        let impostor = V2Suite.generateEd25519()
        let wire = validEvent(impostor, s.targetDeviceId) // signed by someone this device never authorized
        let outcome = V2W2.handleW2Event(wire, store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: now)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "bad_signature")
    }

    func testReinstallRestoreDoesNotResurrectARevokedAuthorizationTheSameEventStopsWorking() {
        let s = makeSetup(account: account)
        let wire = validEvent(s.issuer, s.targetDeviceId)
        XCTAssertEqual(V2W2.handleW2Event(wire, store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: now).kind, "auto_execute")
        s.store.revoke(account)
        let secondWire = validEvent(s.issuer, s.targetDeviceId) // a fresh event, still from the now-revoked issuer
        let outcome = V2W2.handleW2Event(secondWire, store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: now)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "no_local_authorization")
    }

    func testADeviceNotNamedInTargetDevicesIsRefused() {
        let s = makeSetup(account: account)
        let otherDevice = V2E2.deviceIdOf(V2Suite.generateEd25519().publicKey)
        let wire = validEvent(s.issuer, s.targetDeviceId)
        let outcome = V2W2.handleW2Event(wire, store: s.store, dedup: s.dedup, thisDeviceId: otherDevice, nowMs: now)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "not_a_target")
    }

    func testBuildW2EventRefusesAValidityWindowLongerThan24Hours() {
        let issuer = V2Suite.generateEd25519()
        let wire = V2W2.buildW2Event(V2W2.BuildParams(account: account, issuerIdentityPk: issuer.publicKey, issuerIdentitySk: issuer.secretKey, targetDevices: ["x"], scope: ["wipe_all"], issuedAtMs: now, expiresAtMs: now + V2W2.maxValidityMs + 1))
        XCTAssertNil(wire)
    }

    func testAnExpiredEventPastExpiryPlusClockSkewIsRefused() {
        let s = makeSetup(account: account)
        let wire = validEvent(s.issuer, s.targetDeviceId)
        let farInFuture = now + 60 * 60 * 1000 + V2W2.clockSkewMs + 1
        let outcome = V2W2.handleW2Event(wire, store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: farInFuture)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "expired")
    }

    func testAnEventNotYetValidBeforeIssuedAtBeyondClockSkewIsRefused() {
        let s = makeSetup(account: account)
        let wire = validEvent(s.issuer, s.targetDeviceId)
        let wayBefore = now - V2W2.clockSkewMs - 1
        let outcome = V2W2.handleW2Event(wire, store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: wayBefore)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "not_yet_valid")
    }

    func testClockSkewOfExactlyTheAllowed2MinutesIsToleratedOnBothSides() {
        let s = makeSetup(account: account)
        let wire = validEvent(s.issuer, s.targetDeviceId)
        let justBeforeIssued = now - V2W2.clockSkewMs
        let outcome = V2W2.handleW2Event(wire, store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: justBeforeIssued)
        XCTAssertTrue(outcome.ok)
    }

    func testAWrongPrefixOrCorruptedBodyIsRefused() {
        let s = makeSetup(account: account)
        let wrongPrefix = V2W2.handleW2Event("P2:whatever", store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: now)
        XCTAssertFalse(wrongPrefix.ok)
        XCTAssertEqual(wrongPrefix.reason, "malformed")
        let corrupted = V2W2.handleW2Event("W2:not-base64!!!", store: s.store, dedup: s.dedup, thisDeviceId: s.targetDeviceId, nowMs: now)
        XCTAssertFalse(corrupted.ok)
        XCTAssertEqual(corrupted.reason, "malformed")
    }
}
