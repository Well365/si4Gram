import XCTest
@testable import SecutgCore

/// Real-device report 2026-10-01: account A has a Mac (O, identity IO) and an iPhone (N, identity IN); B starts
/// auto-pairing in the chat. Both A devices cache B's INVITE; O accepts and completes SELECT / CONFIRM / READY with B;
/// N keeps offering 〔同意配对〕 (bug 1), then scans O's V2Q (PLAN.md 3.39.13) and must end up paired, reading the
/// earlier B→A and O→B messages, and sending to both (bug 2 / item 3).
///
/// Only the entry points the runtimes call, in the order they call them, with Telegram's `isOutgoing` flag and real
/// asymmetric chat ids: O's messages reach N as outgoing, B's as incoming.
final class V2SiblingAcceptCloneTests: XCTestCase {
    private let userA = "7101"
    private let userB = "8202"

    private final class Clock {
        var ms: Int64 = 1_790_300_000_000
    }

    private let clock = Clock()

    private final class Device {
        let key: String
        let userId: String
        let chat: String
        let storage: V2MemoryStorage
        let identity: KeyRing.Identity
        var runtime: V2Runtime

        init(key: String, userId: String, chat: String, storage: V2MemoryStorage, identity: KeyRing.Identity, runtime: V2Runtime) {
            self.key = key
            self.userId = userId
            self.chat = chat
            self.storage = storage
            self.identity = identity
            self.runtime = runtime
        }
    }

    private var devices: [Device] = []

    override func tearDown() {
        for device in devices { V2RuntimeRegistry.shared.reset(for: device.key) }
        devices = []
        super.tearDown()
    }

    /// `skewMs`: how far this device's clock runs ahead of the others' (real devices never agree to the millisecond).
    private func makeDevice(_ key: String, userId: String, skewMs: Int64 = 0) -> Device {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        let identity = KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
        let storage = V2MemoryStorage()
        let clock = self.clock
        let runtime = V2Runtime(identity: V2IdentityBridge.identity(userId: userId, from: identity)!, persisted: V2PersistedState.load(storage: storage), now: { clock.ms + skewMs })
        V2RuntimeRegistry.shared.set(runtime, for: "sib-" + key)
        let device = Device(key: "sib-" + key, userId: userId, chat: userId == userA ? userB : userA, storage: storage, identity: identity, runtime: runtime)
        devices.append(device)
        return device
    }

    private func restart(_ device: Device) {
        let clock = self.clock
        device.runtime = V2Runtime(identity: V2IdentityBridge.identity(userId: device.userId, from: device.identity)!, persisted: V2PersistedState.load(storage: device.storage), now: { clock.ms })
        V2RuntimeRegistry.shared.set(device.runtime, for: device.key)
    }

    @discardableResult
    private func render(_ wire: String, on device: Device, sentBy sender: Device) -> V2PairingReceiveOutcome {
        return V2PairingDispatch.handleIncoming(accountKey: device.key, chatId: device.chat, wireText: wire, isOutgoing: sender.userId == device.userId)
    }

    private func onward(_ outcome: V2PairingReceiveOutcome) -> String? {
        if case let .progressed(wire?) = outcome { return wire }
        return nil
    }

    private func status(_ device: Device) -> V2PairingStatus {
        return V2PairingStatus.of(accountKey: device.key, chatId: device.chat)
    }

    private func send(_ device: Device, _ text: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        switch V2Dispatch.prepareOutgoingText(accountKey: device.key, chatId: device.chat, text: text) {
        case let .sent(wire): return wire
        case let other:
            XCTFail("\(device.key) cannot send: \(other)", file: file, line: line)
            return nil
        }
    }

    private func read(_ device: Device, _ wire: String) -> String {
        switch V2Dispatch.decryptIncomingText(accountKey: device.key, chatId: device.chat, wireText: wire) {
        case let .decrypted(text): return text
        case let .failed(reason): return "<failed:\(reason)>"
        case .notV2: return "<notV2>"
        }
    }

    /// The five P2 messages of B ↔ O, as each device in the chat would see them.
    private struct Handshake {
        let invite: String
        let accept: String
        let select: String
        let confirm: String
        let ready: String
    }

    /// B invites; O and N render the INVITE (both cache it); O accepts; the rest of the handshake runs between O and B
    /// only. N's renders of the later steps are left to the caller (`order`), so the arrival order can vary.
    private func runHandshake(o: Device, n: Device, b: Device, file: StaticString = #filePath, line: UInt = #line) -> Handshake? {
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: b.key, chatId: b.chat, targetUser: userA) else {
            XCTFail("B invite", file: file, line: line); return nil
        }
        render(invite, on: b, sentBy: b)
        guard case let .invited(_, _, cachedAtO) = render(invite, on: o, sentBy: b) else { XCTFail("O did not cache", file: file, line: line); return nil }
        clock.ms += 1_000
        guard case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: o.key, chatId: o.chat, inviteWire: cachedAtO) else {
            XCTFail("O accept", file: file, line: line); return nil
        }
        render(accept, on: o, sentBy: o)
        guard let select = onward(render(accept, on: b, sentBy: o)) else { XCTFail("B select", file: file, line: line); return nil }
        render(select, on: b, sentBy: b)
        guard let confirm = onward(render(select, on: o, sentBy: b)) else { XCTFail("O confirm", file: file, line: line); return nil }
        render(confirm, on: o, sentBy: o)
        guard let ready = onward(render(confirm, on: b, sentBy: o)) else { XCTFail("B ready", file: file, line: line); return nil }
        render(ready, on: b, sentBy: b)
        _ = render(ready, on: o, sentBy: b)
        XCTAssertEqual(status(o).pairingState, "paired", file: file, line: line)
        XCTAssertEqual(status(b).pairingState, "paired", file: file, line: line)
        return Handshake(invite: invite, accept: accept, select: select, confirm: confirm, ready: ready)
    }

    /// O shows the code, N installs it.
    private func clone(o: Device, n: Device, file: StaticString = #filePath, line: UInt = #line) -> V2PairingDispatch.JoinInstallOutcome {
        clock.ms += 1_000
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat) else {
            XCTFail("O share", file: file, line: line); return .notOnV2
        }
        if case let .refused(refusal) = V2PairingDispatch.inspectJoin(accountKey: n.key, chatId: n.chat, text: share.text) {
            XCTFail("N inspect refused: \(refusal)", file: file, line: line)
        }
        clock.ms += 1_000
        return V2PairingDispatch.installJoin(accountKey: n.key, chatId: n.chat, text: share.text)
    }

    /// The user's sequence after the handshake: O and B write, N stores both undecryptable, N imports O's code, N reads
    /// them, N writes and both O and B read it.
    private func cloneAndCheckInterop(o: Device, n: Device, b: Device, file: StaticString = #filePath, line: UInt = #line) {
        guard let fromB = send(b, "B→A before", file: file, line: line), let fromO = send(o, "O→B before", file: file, line: line) else { return }
        XCTAssertEqual(read(o, fromB), "B→A before", file: file, line: line)
        XCTAssertEqual(read(b, fromO), "O→B before", file: file, line: line)
        XCTAssertTrue(read(n, fromB).hasPrefix("<failed:"), "N stores B's message undecryptable", file: file, line: line)
        XCTAssertTrue(read(n, fromO).hasPrefix("<failed:"), "N stores O's message undecryptable", file: file, line: line)

        XCTAssertEqual(clone(o: o, n: n, file: file, line: line), .installed, "N's import", file: file, line: line)

        // the redecrypt sweep: the same receive function again over the stored rows
        XCTAssertEqual(read(n, fromB), "B→A before", file: file, line: line)
        XCTAssertEqual(read(n, fromO), "O→B before", file: file, line: line)
        guard let fromN = send(n, "N after import", file: file, line: line) else { return }
        XCTAssertEqual(read(b, fromN), "N after import", file: file, line: line)
        XCTAssertEqual(read(o, fromN), "N after import", file: file, line: line)
        guard let fromB2 = send(b, "B after import", file: file, line: line) else { return }
        XCTAssertEqual(read(n, fromB2), "B after import", file: file, line: line)

        let after = status(n)
        XCTAssertEqual(after.pairingState, "paired", file: file, line: line)
        XCTAssertFalse(after.hasIncomingInvite, "after import no 〔同意配对〕", file: file, line: line)
        XCTAssertEqual(after.safetyCode, status(o).safetyCode, file: file, line: line)
        XCTAssertNil(n.runtime.persisted.incomingInviteStore.get(n.chat), "the cached invite is gone", file: file, line: line)
        XCTAssertNil(n.runtime.pairing.currentTransactionForChat(n.chat), "no own transaction left", file: file, line: line)
        restart(n)
        XCTAssertEqual(status(n).pairingState, "paired", file: file, line: line)
        XCTAssertFalse(status(n).hasIncomingInvite, file: file, line: line)
    }

    // MARK: bug 1 — the sibling's ACCEPT closes this device's cached invite

    func testSiblingAcceptDropsTheCachedInviteAndSaysWhatToDo() throws {
        let o = makeDevice("O", userId: userA), b = makeDevice("B", userId: userB), n = makeDevice("N", userId: userA)
        clock.ms += 1_000
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: b.key, chatId: b.chat, targetUser: userA) else { return XCTFail("invite") }
        guard case .invited = render(invite, on: n, sentBy: b) else { return XCTFail("N did not cache") }
        XCTAssertTrue(status(n).hasIncomingInvite, "N offers 〔同意配对〕 while nobody has accepted")
        guard case let .invited(_, _, cached) = render(invite, on: o, sentBy: b) else { return XCTFail("O did not cache") }
        clock.ms += 1_000
        guard case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: o.key, chatId: o.chat, inviteWire: cached) else { return XCTFail("O accept") }

        XCTAssertEqual(render(accept, on: n, sentBy: o), .ignored(reason: V2PairingDispatch.siblingAcceptedReason))
        XCTAssertEqual(V2PairingDispatch.ignoredLine(reason: V2PairingDispatch.siblingAcceptedReason, wire: accept), .siblingAccepted)
        XCTAssertNil(n.runtime.persisted.incomingInviteStore.get(n.chat))
        XCTAssertFalse(status(n).hasIncomingInvite, "no 〔同意配对〕 once the account accepted elsewhere")
        XCTAssertNil(status(n).pairingState)
        // accepting it anyway (a stale button) cannot start a competing pairing
        guard case .failed = V2PairingDispatch.acceptInvite(accountKey: n.key, chatId: n.chat, inviteWire: invite) else { return XCTFail("N could accept") }
        // persisted: a restart does not bring the button back, nor does the INVITE re-rendering
        restart(n)
        XCTAssertFalse(status(n).hasIncomingInvite)
        XCTAssertEqual(render(invite, on: n, sentBy: b), .ignored(reason: V2PairingDispatch.inviteClosedReason))
        XCTAssertFalse(status(n).hasIncomingInvite, "the INVITE re-rendering does not resurrect it")
        // nor do the rest of the handshake's steps
        guard let select = onward(render(accept, on: b, sentBy: o)) else { return XCTFail("B select") }
        render(select, on: n, sentBy: b)
        guard let confirm = onward(render(select, on: o, sentBy: b)) else { return XCTFail("O confirm") }
        render(confirm, on: n, sentBy: o)
        guard let ready = onward(render(confirm, on: b, sentBy: o)) else { return XCTFail("B ready") }
        render(ready, on: n, sentBy: b)
        render(ready, on: o, sentBy: b)
        XCTAssertFalse(status(n).hasIncomingInvite)
        XCTAssertNil(n.runtime.persisted.incomingInviteStore.get(n.chat))
        // the device that accepted is unaffected
        XCTAssertEqual(status(o).pairingState, "paired")
    }

    func testAnUnrelatedSiblingAcceptLeavesANewerInviteAlone() throws {
        let o = makeDevice("O", userId: userA), b = makeDevice("B", userId: userB), n = makeDevice("N", userId: userA)
        clock.ms += 1_000
        guard let first = runHandshake(o: o, n: n, b: b) else { return }
        // B pairs again later (it reset); N caches the new invite; O's OLD accept re-rendering must not drop it
        _ = V2PairingDispatch.unpair(accountKey: b.key, chatId: b.chat)
        clock.ms += 60_000
        guard case let .sent(second) = V2PairingDispatch.startPairing(accountKey: b.key, chatId: b.chat, targetUser: userA) else { return XCTFail("invite 2") }
        guard case .invited = render(second, on: n, sentBy: b) else { return XCTFail("N did not cache the second invite") }
        _ = render(first.accept, on: n, sentBy: o)
        XCTAssertEqual(n.runtime.persisted.incomingInviteStore.get(n.chat), second)
        XCTAssertTrue(status(n).hasIncomingInvite)
    }

    func testAForeignAccountsAcceptIsNotASibling() throws {
        let o = makeDevice("O", userId: userA), b = makeDevice("B", userId: userB), n = makeDevice("N", userId: userA)
        clock.ms += 1_000
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: b.key, chatId: b.chat, targetUser: userA) else { return XCTFail("invite") }
        guard case .invited = render(invite, on: n, sentBy: b) else { return XCTFail("N did not cache") }
        guard case let .invited(_, _, cached) = render(invite, on: o, sentBy: b) else { return XCTFail("O did not cache") }
        guard case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: o.key, chatId: o.chat, inviteWire: cached) else { return XCTFail("O accept") }
        // the same bytes arriving as INCOMING (someone else posted them) are not this account's
        _ = V2PairingDispatch.handleIncoming(accountKey: n.key, chatId: n.chat, wireText: accept, isOutgoing: false)
        XCTAssertNotNil(n.runtime.persisted.incomingInviteStore.get(n.chat))
        // a tampered outgoing ACCEPT (signature broken) is not either
        let tampered = String(accept.dropLast(2)) + (accept.hasSuffix("AA") ? "BB" : "AA")
        _ = render(tampered, on: n, sentBy: o)
        XCTAssertNotNil(n.runtime.persisted.incomingInviteStore.get(n.chat))
    }

    // MARK: item 3 — the user's exact sequence, then the clone

    func testUsersSequenceThenCloneReadsAndWritesEverywhere() throws {
        let o = makeDevice("O", userId: userA), b = makeDevice("B", userId: userB), n = makeDevice("N", userId: userA)
        clock.ms += 1_000
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: b.key, chatId: b.chat, targetUser: userA) else { return XCTFail("invite") }
        render(invite, on: b, sentBy: b)
        guard case .invited = render(invite, on: n, sentBy: b) else { return XCTFail("N did not cache") }
        guard case let .invited(_, _, cached) = render(invite, on: o, sentBy: b) else { return XCTFail("O did not cache") }
        clock.ms += 1_000
        guard case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: o.key, chatId: o.chat, inviteWire: cached) else { return XCTFail("O accept") }
        render(accept, on: o, sentBy: o)
        render(accept, on: n, sentBy: o)
        guard let select = onward(render(accept, on: b, sentBy: o)) else { return XCTFail("B select") }
        render(select, on: b, sentBy: b)
        render(select, on: n, sentBy: b)
        guard let confirm = onward(render(select, on: o, sentBy: b)) else { return XCTFail("O confirm") }
        render(confirm, on: o, sentBy: o)
        render(confirm, on: n, sentBy: o)
        guard let ready = onward(render(confirm, on: b, sentBy: o)) else { return XCTFail("B ready") }
        render(ready, on: b, sentBy: b)
        render(ready, on: n, sentBy: b)
        render(ready, on: o, sentBy: b)
        XCTAssertFalse(status(n).hasIncomingInvite, "bug 1: N still offers 〔同意配对〕 after O completed the pairing")
        cloneAndCheckInterop(o: o, n: n, b: b)
    }

    /// Variant (a): N tapped 〔同意配对〕 too, before it saw O's ACCEPT; B took O's (it arrived first). N's losing responder
    /// transaction must not block the import, and the import replaces it.
    func testVariantANAcceptedTooAndLostThenClones() throws {
        let o = makeDevice("O", userId: userA), b = makeDevice("B", userId: userB), n = makeDevice("N", userId: userA)
        clock.ms += 1_000
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: b.key, chatId: b.chat, targetUser: userA) else { return XCTFail("invite") }
        guard case let .invited(_, _, cachedAtN) = render(invite, on: n, sentBy: b) else { return XCTFail("N did not cache") }
        guard case let .invited(_, _, cachedAtO) = render(invite, on: o, sentBy: b) else { return XCTFail("O did not cache") }
        clock.ms += 1_000
        guard case let .sent(acceptO) = V2PairingDispatch.acceptInvite(accountKey: o.key, chatId: o.chat, inviteWire: cachedAtO) else { return XCTFail("O accept") }
        guard case let .sent(acceptN) = V2PairingDispatch.acceptInvite(accountKey: n.key, chatId: n.chat, inviteWire: cachedAtN) else { return XCTFail("N accept") }
        XCTAssertEqual(status(n).pairingState, "invited")
        // B gets O's first
        guard let select = onward(render(acceptO, on: b, sentBy: o)) else { return XCTFail("B select") }
        XCTAssertNil(onward(render(acceptN, on: b, sentBy: n)), "B refuses the second ACCEPT")
        // N sees O's ACCEPT (a sibling's) and its own echo, O sees N's (a sibling's)
        render(acceptN, on: n, sentBy: n)
        render(acceptO, on: n, sentBy: o)
        render(acceptN, on: o, sentBy: n)
        render(select, on: n, sentBy: b)
        guard let confirm = onward(render(select, on: o, sentBy: b)) else { return XCTFail("O confirm") }
        render(confirm, on: n, sentBy: o)
        guard let ready = onward(render(confirm, on: b, sentBy: o)) else { return XCTFail("B ready") }
        render(ready, on: n, sentBy: b)
        render(ready, on: o, sentBy: b)
        XCTAssertEqual(status(o).pairingState, "paired")
        XCTAssertNil(n.runtime.pairing.bindingStore.current(n.chat), "N lost the race")
        cloneAndCheckInterop(o: o, n: n, b: b)
    }

    /// Variant (b): N gets the pairing's P2 messages in a different order — O's ACCEPT and B's SELECT before B's INVITE.
    func testVariantBOutOfOrderThenClones() throws {
        let o = makeDevice("O", userId: userA), b = makeDevice("B", userId: userB), n = makeDevice("N", userId: userA)
        clock.ms += 1_000
        guard let h = runHandshake(o: o, n: n, b: b) else { return }
        render(h.ready, on: n, sentBy: b)
        render(h.accept, on: n, sentBy: o)
        render(h.select, on: n, sentBy: b)
        render(h.invite, on: n, sentBy: b)
        render(h.confirm, on: n, sentBy: o)
        XCTAssertFalse(status(n).hasIncomingInvite, "an INVITE arriving after its sibling ACCEPT is not offered")
        XCTAssertNil(n.runtime.persisted.incomingInviteStore.get(n.chat))
        cloneAndCheckInterop(o: o, n: n, b: b)
    }

    /// Variant (b'): N was offline for the whole handshake and the messages arrive only after it imported (catch-up).
    func testVariantBHandshakeArrivesAfterTheImport() throws {
        let o = makeDevice("O", userId: userA), b = makeDevice("B", userId: userB), n = makeDevice("N", userId: userA)
        clock.ms += 1_000
        guard let h = runHandshake(o: o, n: n, b: b) else { return }
        guard let fromB = send(b, "B→A before"), let fromO = send(o, "O→B before") else { return }
        XCTAssertEqual(clone(o: o, n: n), .installed)
        for (wire, sender) in [(h.invite, b), (h.accept, o), (h.select, b), (h.confirm, o), (h.ready, b)] { render(wire, on: n, sentBy: sender) }
        XCTAssertNotNil(n.runtime.pairing.bindingStore.current(n.chat), "the handshake that made the shared binding does not set it aside")
        XCTAssertFalse(status(n).hasIncomingInvite)
        XCTAssertEqual(read(n, fromB), "B→A before")
        XCTAssertEqual(read(n, fromO), "O→B before")
        guard let fromN = send(n, "N after") else { return }
        XCTAssertEqual(read(b, fromN), "N after")
        XCTAssertEqual(read(o, fromN), "N after")
    }

    // MARK: bug 2 — status never offers the invite the binding came from

    func testStatusNeverOffersTheInviteTheBindingCameFrom() throws {
        // B's clock runs two minutes ahead: its INVITE "post-dates" O's binding by the clock alone
        let o = makeDevice("O", userId: userA), b = makeDevice("B", userId: userB, skewMs: 120_000), n = makeDevice("N", userId: userA)
        clock.ms += 1_000
        guard let h = runHandshake(o: o, n: n, b: b) else { return }
        let binding = try XCTUnwrap(o.runtime.pairing.bindingStore.current(o.chat))
        XCTAssertEqual(binding.txnId, V2Envelope.parse(prefix: V2Messages.prefix, text: h.invite)?.txnId)
        XCTAssertTrue(V2PairingDispatch.isInviteNewer(thanBindingInstalledAtMs: binding.installedAtMs, inviteWire: h.invite))
        o.runtime.persisted.incomingInviteStore.set(o.chat, wire: h.invite)
        XCTAssertFalse(V2PairingStatus.of(o.runtime, chatId: o.chat).hasIncomingInvite, "the invite the binding came from is never offered")
        XCTAssertEqual(render(h.invite, on: o, sentBy: b), .ignored(reason: V2PairingDispatch.inviteClosedReason))
    }

    /// The clone's binding names no wire transaction, so the clock is all the status has — unless the import closed the
    /// invite, which it now does: with N's clock behind B's, the old invite still "post-dates" the clone binding.
    func testCloneImportClosesTheInviteEvenWithASkewedClock() throws {
        let o = makeDevice("O", userId: userA), b = makeDevice("B", userId: userB, skewMs: 300_000), n = makeDevice("N", userId: userA)
        clock.ms += 1_000
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: b.key, chatId: b.chat, targetUser: userA) else { return XCTFail("invite") }
        guard case .invited = render(invite, on: n, sentBy: b) else { return XCTFail("N did not cache") }
        guard case let .invited(_, _, cached) = render(invite, on: o, sentBy: b) else { return XCTFail("O did not cache") }
        guard case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: o.key, chatId: o.chat, inviteWire: cached) else { return XCTFail("O accept") }
        guard let select = onward(render(accept, on: b, sentBy: o)) else { return XCTFail("B select") }
        guard let confirm = onward(render(select, on: o, sentBy: b)) else { return XCTFail("O confirm") }
        guard let ready = onward(render(confirm, on: b, sentBy: o)) else { return XCTFail("B ready") }
        render(ready, on: o, sentBy: b)
        // N never saw O's ACCEPT (it was offline), so only the import can close the invite
        XCTAssertTrue(status(n).hasIncomingInvite)
        XCTAssertEqual(clone(o: o, n: n), .installed)
        XCTAssertFalse(status(n).hasIncomingInvite)
        XCTAssertEqual(render(invite, on: n, sentBy: b), .ignored(reason: V2PairingDispatch.inviteClosedReason))
        XCTAssertFalse(status(n).hasIncomingInvite)
        XCTAssertEqual(status(n).pairingState, "paired")
    }
}
