import XCTest
@testable import SecutgCore

/// PLAN.md 3.43: an INVITE on a chat that already has a binding is an ordinary re-pair when its identity is one the
/// binding knows, and 「钥匙变了」 when it is not — and in that case nothing is adopted until the user accepts.
final class V2InviteKeyChangedTests: XCTestCase {
    private let chat = "4200"

    private func makeStoredIdentity() -> KeyRing.Identity {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        return KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
    }

    private func makeRuntime(userId: String) -> V2Runtime {
        let identity = V2IdentityBridge.identity(userId: userId, from: makeStoredIdentity())!
        return V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: V2MemoryStorage()))
    }

    override func tearDown() {
        V2RuntimeRegistry.shared.reset(for: "deviceA")
        V2RuntimeRegistry.shared.reset(for: "deviceB")
        V2RuntimeRegistry.shared.reset(for: "deviceA2")
        super.tearDown()
    }

    /// A (user 100) and B (user 200) pair through the real dispatch, so B holds a binding whose roster is A's device.
    private func pair(_ a: V2Runtime, _ b: V2Runtime) throws {
        guard case .sent(let inviteWire) = V2PairingDispatch.startPairing(accountKey: "deviceA", chatId: chat, targetUser: "200") else { return XCTFail("invite") }
        guard case .invited = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: inviteWire, isOutgoing: false) else { return XCTFail("invited") }
        guard case .sent(let acceptWire) = V2PairingDispatch.acceptInvite(accountKey: "deviceB", chatId: chat, inviteWire: inviteWire) else { return XCTFail("accept") }
        guard case .progressed(let selectWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: acceptWire, isOutgoing: false) else { return XCTFail("select") }
        guard case .progressed(let confirmWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: selectWire, isOutgoing: false) else { return XCTFail("confirm") }
        guard case .progressed(let readyWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: confirmWire, isOutgoing: false) else { return XCTFail("ready") }
        guard case .progressed(nil) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: readyWire, isOutgoing: false) else { return XCTFail("done") }
        XCTAssertNotNil(a.pairing.bindingStore.current(chat))
        XCTAssertNotNil(b.pairing.bindingStore.current(chat))
    }

    /// The wire is dated after the binding, as a real reinstall's invite is (`V2PairingStatus` only offers newer ones).
    private func later() {
        Thread.sleep(forTimeInterval: 0.002)
    }

    func testWithoutABindingAnInviteIsAnOrdinaryInvite() {
        let a = makeRuntime(userId: "100")
        let b = makeRuntime(userId: "200")
        V2RuntimeRegistry.shared.set(a, for: "deviceA")
        V2RuntimeRegistry.shared.set(b, for: "deviceB")
        guard case .sent(let inviteWire) = V2PairingDispatch.startPairing(accountKey: "deviceA", chatId: chat, targetUser: "200") else { return XCTFail("invite") }
        guard case .invited(let fromUser, _, _) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: inviteWire, isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        XCTAssertEqual(fromUser, "100")
    }

    func testWithABindingAnInviteFromTheSameIdentityIsAnOrdinaryInvite() throws {
        let a = makeRuntime(userId: "100")
        let b = makeRuntime(userId: "200")
        V2RuntimeRegistry.shared.set(a, for: "deviceA")
        V2RuntimeRegistry.shared.set(b, for: "deviceB")
        try pair(a, b)
        let before = try XCTUnwrap(b.pairing.bindingStore.current(chat))
        later()
        // The same device invites again (a re-pair from the peer's own lock menu after unpairing on their side only).
        guard case .sent(let again) = V2PairingDispatch.startPairing(accountKey: "deviceA", chatId: chat, targetUser: "200") else { return XCTFail("invite") }
        guard case .invited(let fromUser, _, let cached) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: again, isOutgoing: false) else {
            return XCTFail("expected .invited — the identity is in the roster")
        }
        XCTAssertEqual(fromUser, "100")
        XCTAssertEqual(cached, again)
        XCTAssertEqual(b.pairing.bindingStore.current(chat)?.bindingId, before.bindingId, "nothing adopted")
        XCTAssertTrue(V2PairingDispatch.inviteIdentityIsInRoster(before, inviteIdentityPk: V2Messages.parseInvite(again)!.body.identityPk))
    }

    func testWithABindingAnInviteFromAnUnknownIdentityIsKeyChangedAndAdoptsNothing() throws {
        let a = makeRuntime(userId: "100")
        let b = makeRuntime(userId: "200")
        V2RuntimeRegistry.shared.set(a, for: "deviceA")
        V2RuntimeRegistry.shared.set(b, for: "deviceB")
        try pair(a, b)
        let before = try XCTUnwrap(b.pairing.bindingStore.current(chat))
        later()
        // User 100 reinstalled — or somebody is wearing their name: a fresh identity, same user id.
        let a2 = makeRuntime(userId: "100")
        V2RuntimeRegistry.shared.set(a2, for: "deviceA2")
        guard case .sent(let fresh) = V2PairingDispatch.startPairing(accountKey: "deviceA2", chatId: chat, targetUser: "200") else { return XCTFail("invite") }
        let parsed = try XCTUnwrap(V2Messages.parseInvite(fresh))
        XCTAssertFalse(V2PairingDispatch.inviteIdentityIsInRoster(before, inviteIdentityPk: parsed.body.identityPk))

        guard case .invitedKeyChanged(let fromUser, let targetUser, let cached, let oldDeviceCode, let newDeviceCode)
                = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: fresh, isOutgoing: false) else {
            return XCTFail("expected .invitedKeyChanged")
        }
        XCTAssertEqual(fromUser, "100")
        XCTAssertEqual(targetUser, "200")
        XCTAssertEqual(cached, fresh)
        // Rule 2: nothing adopted — the binding, its id and its roster are exactly what they were.
        let after = try XCTUnwrap(b.pairing.bindingStore.current(chat))
        XCTAssertEqual(after.bindingId, before.bindingId)
        XCTAssertEqual(after.deviceRoster, before.deviceRoster)
        XCTAssertTrue(b.pairing.canSend(chat), "the old binding keeps working")
        // The invite is cached like any other, so the same 〔同意配对〕 accepts it.
        XCTAssertEqual(b.persisted.incomingInviteStore.get(chat), fresh)
        XCTAssertTrue(V2PairingStatus.of(b, chatId: chat).hasIncomingInvite)
        // Rule 3: no safety code before acceptance — the peer cannot compute one yet. The row names the two devices
        // and asks the user to verify the person: the old device (A's, from the binding) and the new one (the invite).
        XCTAssertEqual(oldDeviceCode, V2JoinCoordinator.deviceCode(encapsulationPkB64: Base64Url.encode(a.identity.encapsulationPk), fallback: "?"))
        XCTAssertEqual(newDeviceCode, V2JoinCoordinator.deviceCode(encapsulationPkB64: Base64Url.encode(a2.identity.encapsulationPk), fallback: "?"))
        XCTAssertNotEqual(oldDeviceCode, newDeviceCode)

        // Accepting is unchanged: a new binding, a new code, the old one historical.
        guard case .sent = V2PairingDispatch.acceptInvite(accountKey: "deviceB", chatId: chat, inviteWire: cached) else { return XCTFail("accept") }
        XCTAssertNil(b.persisted.incomingInviteStore.get(chat))
    }
}
