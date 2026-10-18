import XCTest
@testable import SecutgCore

/// Covers the real, non-cosmetic bug fixed alongside wiring `V2Bootstrap.initV2Worker` into
/// `Account.init`: unlike `SecutgHookRegistry.install` (which checks its own account cache first
/// and returns the existing runtime rather than rebuilding), `initV2Worker` used to unconditionally
/// build a brand-new `V2Runtime` and overwrite the registry entry on every call. `Account.init` can
/// run more than once per process for the same account (account rebuilds), so a second call used to
/// silently drop any in-flight pairing transaction recorded against the first call's runtime.
final class V2BootstrapIdempotencyTests: XCTestCase {
    private let accountKey = "V2BootstrapIdempotencyTests-account"
    private let basePath = NSTemporaryDirectory()

    private func makeStoredIdentity() -> KeyRing.Identity {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        return KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
    }

    override func tearDown() {
        V2RuntimeRegistry.shared.reset(for: accountKey)
        super.tearDown()
    }

    func testInitV2WorkerReturnsTheSameRuntimeInstanceOnASecondCallForTheSameAccount() {
        let identity = makeStoredIdentity()

        let first = V2Bootstrap.initV2Worker(accountKey: accountKey, userId: "100", basePath: basePath, storedIdentity: identity)
        let second = V2Bootstrap.initV2Worker(accountKey: accountKey, userId: "100", basePath: basePath, storedIdentity: identity)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "a second initV2Worker call for the same accountKey must return the SAME V2Runtime instance, not rebuild one")
    }

    func testInitV2WorkerDoesNotLoseAnInFlightPairingTransactionRecordedBetweenTwoCalls() {
        let identity = makeStoredIdentity()

        // First call: real app-startup shape (e.g. the first `Account.init` for this process).
        guard let runtimeAfterFirstCall = V2Bootstrap.initV2Worker(accountKey: accountKey, userId: "100", basePath: basePath, storedIdentity: identity) else {
            return XCTFail("expected a runtime once a v1 identity exists")
        }

        // Something records in-flight pairing state on THAT runtime instance — mirrors a pairing
        // already under way when `Account.init` happens to run again (account rebuild).
        let invite = runtimeAfterFirstCall.pairing.startPairing("4200", "200")
        guard let txnId = invite?.txnId else {
            return XCTFail("expected startPairing to produce an in-flight transaction")
        }
        XCTAssertEqual(runtimeAfterFirstCall.pairing.phaseOf(txnId), .invited)

        // Second call: same accountKey, same process — the exact shape of an `Account.init` rebuild.
        // The old, non-idempotent `initV2Worker` would build a fresh `V2Runtime` here (a fresh
        // `PairingProcessor` with an empty in-memory pending-transaction store), silently losing the
        // invite recorded above.
        guard let runtimeAfterSecondCall = V2Bootstrap.initV2Worker(accountKey: accountKey, userId: "100", basePath: basePath, storedIdentity: identity) else {
            return XCTFail("expected a runtime on the second call too")
        }

        XCTAssertTrue(runtimeAfterSecondCall === runtimeAfterFirstCall)
        XCTAssertEqual(runtimeAfterSecondCall.pairing.phaseOf(txnId), .invited, "the in-flight pairing transaction from before the second initV2Worker call must still be there")

        // The transaction is still fully usable, not just structurally present: the responder side
        // can still complete the handshake against the accountKey the second call returned.
        let responderIdentity = makeStoredIdentity()
        let responderRuntime = V2Runtime(identity: V2IdentityBridge.identity(userId: "200", from: responderIdentity)!, persisted: V2PersistedState.load(storage: V2MemoryStorage()))
        let accept = responderRuntime.pairing.acceptInvite(invite!.wire)
        XCTAssertEqual(accept.kind, "accept")
        let afterAccept = runtimeAfterSecondCall.pairing.handleAccept(accept.wire!)
        XCTAssertTrue(afterAccept.ok, "handleAccept must succeed against the pending transaction the FIRST call's runtime recorded")
    }

    func testInitV2WorkerStillReturnsNilRepeatedlyWhenV1HasNoIdentityYet() {
        // Before any runtime has ever been registered for this account (v1 has not created an
        // identity yet), repeated calls must stay a safe no-op — never crash, never register
        // anything — exactly like the pre-fix behavior for this specific case.
        let first = V2Bootstrap.initV2Worker(accountKey: accountKey, userId: "100", basePath: basePath, storedIdentity: nil)
        let second = V2Bootstrap.initV2Worker(accountKey: accountKey, userId: "100", basePath: basePath, storedIdentity: nil)

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertNil(V2RuntimeRegistry.shared.runtime(for: accountKey))
    }
}
