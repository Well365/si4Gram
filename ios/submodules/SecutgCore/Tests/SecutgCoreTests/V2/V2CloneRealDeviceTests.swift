import XCTest
@testable import SecutgCore

/// PLAN.md 3.39.13 — the V2Q clone, end to end, through ONLY the entry points the three runtimes call, in the order
/// they call them, with the `isOutgoing` flag Telegram gives each device and REAL asymmetric chat ids:
///
/// - O (account A) and B (account B) pair through `V2PairingDispatch` exactly like the runtimes do — every P2 message is
///   seen by every device in the chat (the sender's own local copy first, the sender's account siblings as an outgoing
///   message, the peer as an incoming one), and every wire a `.progressed` outcome hands back is relayed;
/// - N (account A, its own global identity) is logged in the whole time and sees all of that traffic too;
/// - O shows the V2Q (`prepareJoinShare`), N inspects and installs it — and from then on N IS O in this chat: same
///   device identity, same keys, B never hears of it.
final class V2CloneRealDeviceTests: XCTestCase {
    private let userA = "7001"
    private let userB = "8002"

    private final class Clock {
        var ms: Int64 = 1_790_200_000_000
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

    // MARK: harness

    private func makeDevice(_ key: String, userId: String) -> Device {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        let identity = KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
        let storage = V2MemoryStorage()
        let clock = self.clock
        let runtime = V2Runtime(identity: V2IdentityBridge.identity(userId: userId, from: identity)!, persisted: V2PersistedState.load(storage: storage), now: { clock.ms })
        V2RuntimeRegistry.shared.set(runtime, for: "clone-" + key)
        // 1v1 chat ids are asymmetric: every device names the chat after the OTHER user.
        let device = Device(key: "clone-" + key, userId: userId, chat: userId == userA ? userB : userA, storage: storage, identity: identity, runtime: runtime)
        devices.append(device)
        return device
    }

    /// The app on `device` was killed and started again: a fresh runtime over what it persisted.
    private func restart(_ device: Device) {
        let clock = self.clock
        device.runtime = V2Runtime(identity: V2IdentityBridge.identity(userId: device.userId, from: device.identity)!, persisted: V2PersistedState.load(storage: device.storage), now: { clock.ms })
        V2RuntimeRegistry.shared.set(device.runtime, for: device.key)
    }

    /// One P2 message rendering on `device`, the way `SecutgAccountRuntime.handleP2` calls it: `isOutgoing` is Telegram's
    /// own out flag — true on every device of the sender's account.
    @discardableResult
    private func render(_ wire: String, on device: Device, sentBy sender: Device) -> V2PairingReceiveOutcome {
        return V2PairingDispatch.handleIncoming(accountKey: device.key, chatId: device.chat, wireText: wire, isOutgoing: sender.userId == device.userId)
    }

    /// `sender` posts a P2 wire into the chat. Its own local copy renders first (iOS / macOS `localCopy`), then everybody
    /// else in `audience`; every `.progressed(wire)` is relayed by the device that got it. Returns every outcome.
    @discardableResult
    private func postP2(_ wire: String, from sender: Device, audience: [Device]) -> [String: V2PairingReceiveOutcome] {
        var outcomes: [String: V2PairingReceiveOutcome] = [:]
        var next: [(Device, String)] = []
        for device in [sender] + audience.filter({ $0 !== sender }) {
            let outcome = render(wire, on: device, sentBy: sender)
            outcomes[device.key] = outcome
            if case let .progressed(onward?) = outcome { next.append((device, onward)) }
        }
        for (device, onward) in next { postP2(onward, from: device, audience: audience) }
        return outcomes
    }

    private func sendE2(_ device: Device, _ text: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        switch V2Dispatch.prepareOutgoingText(accountKey: device.key, chatId: device.chat, text: text) {
        case let .sent(wire): return wire
        case let other:
            XCTFail("\(device.key) cannot send: \(other)", file: file, line: line)
            return nil
        }
    }

    private func readE2(_ device: Device, _ wire: String) -> String {
        switch V2Dispatch.decryptIncomingText(accountKey: device.key, chatId: device.chat, wireText: wire) {
        case let .decrypted(text): return text
        case let .failed(reason): return "<failed:\(reason)>"
        case .notV2: return "<notV2>"
        }
    }

    /// PLAN.md 3.44's render path: the row is stored as its `E2:` wire and opened again at draw time.
    private func openStored(_ device: Device, _ wire: String) -> String {
        switch V2Dispatch.openStoredText(accountKey: device.key, chatId: device.chat, wireText: wire) {
        case let .decrypted(text): return text
        case let .failed(reason): return "<failed:\(reason)>"
        case .notV2: return "<notV2>"
        }
    }

    private func pair(_ x: Device, _ y: Device, watchers: [Device], initiator: Device, file: StaticString = #filePath, line: UInt = #line) {
        let responder = initiator === x ? y : x
        let all = [x, y] + watchers
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: initiator.key, chatId: initiator.chat, targetUser: responder.userId) else {
            return XCTFail("invite", file: file, line: line)
        }
        let atInvite = postP2(invite, from: initiator, audience: all)
        let cached: String
        switch atInvite[responder.key] {
        case let .invited(_, _, wire)?: cached = wire
        case let .invitedKeyChanged(_, _, wire, _, _)?: cached = wire
        default: return XCTFail("responder did not see an invite: \(String(describing: atInvite[responder.key]))", file: file, line: line)
        }
        guard case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: responder.key, chatId: responder.chat, inviteWire: cached) else {
            return XCTFail("accept", file: file, line: line)
        }
        postP2(accept, from: responder, audience: all)
        XCTAssertEqual(V2PairingStatus.of(accountKey: x.key, chatId: x.chat).pairingState, "paired", file: file, line: line)
        XCTAssertEqual(V2PairingStatus.of(accountKey: y.key, chatId: y.chat).pairingState, "paired", file: file, line: line)
    }

    private struct Scene {
        let o: Device
        let n: Device
        let b: Device
        var all: [Device] { return [o, n, b] }
    }

    /// O and B paired (B initiating unless told otherwise), O rekeyed `rekeysBefore` times, both wrote; O shows the code,
    /// N installs it. Returns the scene and B's pre-clone message (N must read it).
    private func cloneScene(initiator: String = "B", rekeysBefore: Int = 0, file: StaticString = #filePath, line: UInt = #line) -> (Scene, String)? {
        let o = makeDevice("O", userId: userA)
        let b = makeDevice("B", userId: userB)
        let n = makeDevice("N", userId: userA)
        let scene = Scene(o: o, n: n, b: b)
        clock.ms += 1_000
        pair(o, b, watchers: [n], initiator: initiator == "B" ? b : o, file: file, line: line)
        for _ in 0..<rekeysBefore {
            clock.ms += 1_000
            guard case let .sent(rekey) = V2PairingDispatch.rekey(accountKey: o.key, chatId: o.chat) else { XCTFail("rekey", file: file, line: line); return nil }
            postP2(rekey, from: o, audience: scene.all)
        }
        guard let fromB = sendE2(b, "B before", file: file, line: line) else { return nil }
        XCTAssertNotEqual(readE2(n, fromB), "B before", "N cannot read before the clone", file: file, line: line)

        clock.ms += 1_000
        let before = o.storage.saved.map { "\($0)" }
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat) else {
            XCTFail("share", file: file, line: line); return nil
        }
        XCTAssertEqual(o.storage.saved.map { "\($0)" }, before, "O writes nothing when it shows a code", file: file, line: line)
        XCTAssertEqual(share.keyCount, 1 + rekeysBefore, file: file, line: line)
        guard case let .ok(inspection) = V2PairingDispatch.inspectJoin(accountKey: n.key, chatId: n.chat, text: share.text) else {
            XCTFail("inspect", file: file, line: line); return nil
        }
        XCTAssertEqual(inspection.safetyCode, V2PairingStatus.of(accountKey: o.key, chatId: o.chat).safetyCode, file: file, line: line)
        clock.ms += 1_000
        guard case .installed = V2PairingDispatch.installJoin(accountKey: n.key, chatId: n.chat, text: share.text) else {
            XCTFail("install", file: file, line: line); return nil
        }
        return (scene, fromB)
    }

    /// E2 in every direction, live and through the 3.44 stored-row path; returns the failures (empty = all good).
    private func e2EveryDirection(_ s: Scene, tag: String) -> [String] {
        var failures: [String] = []
        func check(_ from: Device, _ to: [Device]) {
            let text = "\(tag) \(from.key)"
            guard case let .sent(wire) = V2Dispatch.prepareOutgoingText(accountKey: from.key, chatId: from.chat, text: text) else {
                failures.append("\(from.key) cannot send")
                return
            }
            for device in to {
                let got = readE2(device, wire)
                if got != text { failures.append("\(from.key)→\(device.key): \(got)") }
                let stored = openStored(device, wire)
                if stored != text { failures.append("\(from.key)→\(device.key) stored: \(stored)") }
            }
        }
        check(s.b, [s.o, s.n])
        check(s.n, [s.b, s.o])
        check(s.o, [s.b, s.n])
        return failures
    }

    // MARK: import

    func testNReadsAndWritesTheMomentItImportsAndEveryDirectionDecrypts() throws {
        guard let (s, fromB) = cloneScene(rekeysBefore: 2) else { return }
        XCTAssertEqual(readE2(s.n, fromB), "B before", "N reads history at once")
        let binding = try XCTUnwrap(s.n.runtime.pairing.bindingStore.current(s.n.chat))
        let oBinding = try XCTUnwrap(s.o.runtime.pairing.bindingStore.current(s.o.chat))
        XCTAssertEqual(binding.bindingId, oBinding.bindingId)
        XCTAssertEqual(binding.txnId, "clone:" + binding.bindingId)
        XCTAssertEqual(binding.ownIdentity?.identityPk, Base64Url.encode(s.o.runtime.identity.publicKey), "N acts as O's own device")
        XCTAssertEqual(binding.deviceRoster, oBinding.deviceRoster, "B sees no new device")
        XCTAssertTrue(s.n.runtime.pairing.canSend(s.n.chat))
        XCTAssertEqual(V2PairingStatus.of(accountKey: s.n.key, chatId: s.n.chat).pairingState, "paired")
        XCTAssertEqual(V2PairingStatus.of(accountKey: s.n.key, chatId: s.n.chat).safetyCode, V2PairingStatus.of(accountKey: s.o.key, chatId: s.o.chat).safetyCode)
        // every history master the code carried
        for epoch in 1...binding.epoch { XCTAssertNotNil(s.n.runtime.pairing.keyStore.get(binding.bindingId, epoch)?.master, "epoch \(epoch)") }
        XCTAssertEqual(e2EveryDirection(s, tag: "live"), [])
        // a second code for the same chat on N: already paired
        guard case let .shown(again) = V2PairingDispatch.prepareJoinShare(accountKey: s.o.key, chatId: s.o.chat) else { return XCTFail("share") }
        XCTAssertEqual(V2PairingDispatch.installJoin(accountKey: s.n.key, chatId: s.n.chat, text: again.text), .refused(.alreadyPaired))
    }

    // MARK: rekey

    func testORekeysAndNFollowsAndNRekeysAndOFollows() throws {
        guard let (s, _) = cloneScene() else { return }
        clock.ms += 1_000
        guard case let .sent(fromO) = V2PairingDispatch.rekey(accountKey: s.o.key, chatId: s.o.chat) else { return XCTFail("O rekey") }
        let atO = postP2(fromO, from: s.o, audience: s.all)
        XCTAssertEqual(atO[s.o.key], .ignored(reason: "own_echo:roster_commit"), "O's own local copy is its own echo")
        XCTAssertEqual(atO[s.n.key], .ignored(reason: "own_echo:roster_commit"), "N adopts and words it as the account's own")
        XCTAssertEqual(s.n.runtime.pairing.bindingStore.current(s.n.chat)?.epoch, s.o.runtime.pairing.bindingStore.current(s.o.chat)?.epoch)
        XCTAssertEqual(e2EveryDirection(s, tag: "after O's rekey"), [])

        clock.ms += 1_000
        guard case let .sent(fromN) = V2PairingDispatch.rekey(accountKey: s.n.key, chatId: s.n.chat) else { return XCTFail("N rekey") }
        let atN = postP2(fromN, from: s.n, audience: s.all)
        XCTAssertEqual(atN[s.n.key], .ignored(reason: "own_echo:roster_commit"), "N's local copy runs at enqueue time and must read as its own")
        XCTAssertEqual(atN[s.o.key], .ignored(reason: "own_echo:roster_commit"))
        XCTAssertEqual(atN[s.b.key], .progressed(wire: nil), "B takes it as O's")
        XCTAssertEqual(s.o.runtime.pairing.bindingStore.current(s.o.chat)?.epoch, 3)
        XCTAssertEqual(e2EveryDirection(s, tag: "after N's rekey"), [])
        // the server's dated copy of the same message renders again on N — still its own, still not re-processed
        XCTAssertEqual(render(fromN, on: s.n, sentBy: s.n), .ignored(reason: "own_echo:roster_commit"))
    }

    // MARK: unpair

    func testNUnpairsAndOAndBAreUnpairedToo() throws {
        guard let (s, _) = cloneScene() else { return }
        clock.ms += 1_000
        guard case let .sent(unpair) = V2PairingDispatch.unpair(accountKey: s.n.key, chatId: s.n.chat) else { return XCTFail("N unpair") }
        let outcomes = postP2(unpair, from: s.n, audience: s.all)
        XCTAssertEqual(outcomes[s.n.key], .ignored(reason: "own_echo:unpair"))
        XCTAssertEqual(outcomes[s.o.key], .ignored(reason: "own_echo:unpair"), "O follows its clone, worded as the account's own")
        XCTAssertEqual(outcomes[s.b.key], .progressed(wire: nil))
        for device in s.all { XCTAssertNil(device.runtime.pairing.bindingStore.current(device.chat), device.key) }
        // the same message re-rendering on O later still reads as the account's own unpair
        XCTAssertEqual(render(unpair, on: s.o, sentBy: s.n), .ignored(reason: "own_echo:unpair"))
    }

    func testOUnpairsAndNIsUnpairedToo() throws {
        guard let (s, _) = cloneScene(initiator: "O") else { return }
        clock.ms += 1_000
        guard case let .sent(unpair) = V2PairingDispatch.unpair(accountKey: s.o.key, chatId: s.o.chat) else { return XCTFail("O unpair") }
        let outcomes = postP2(unpair, from: s.o, audience: s.all)
        XCTAssertEqual(outcomes[s.n.key], .ignored(reason: "own_echo:unpair"))
        for device in s.all { XCTAssertNil(device.runtime.pairing.bindingStore.current(device.chat), device.key) }
    }

    // MARK: same-account re-pair

    func testORepairsWithBAndNIsSetAsideAndCanImportTheNewBinding() throws {
        guard let (s, _) = cloneScene() else { return }
        let oldId = try XCTUnwrap(s.n.runtime.pairing.bindingStore.current(s.n.chat)?.bindingId)
        clock.ms += 60_000
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: s.o.key, chatId: s.o.chat, targetUser: userB) else { return XCTFail("invite") }
        let atInvite = postP2(invite, from: s.o, audience: s.all)
        XCTAssertEqual(atInvite[s.o.key], .ignored(reason: "own_echo:invite"))
        XCTAssertEqual(atInvite[s.n.key], .join(.cloneSiblingRepaired), "N: the account paired again elsewhere")
        XCTAssertNil(s.n.runtime.pairing.bindingStore.current(s.n.chat))
        XCTAssertNotNil(s.n.runtime.pairing.tombstoneStore.unpairedFor(oldId), "set aside, not just dropped")
        XCTAssertNotNil(s.n.runtime.pairing.keyStore.get(oldId, 1)?.master, "history keys kept")
        // re-rendering the same message says the same thing
        XCTAssertEqual(render(invite, on: s.n, sentBy: s.o), .join(.cloneSiblingRepaired))
        // finish the pairing; N sees the rest as the account's own steps, nothing re-installs
        guard case let .invited(_, _, cached)? = atInvite[s.b.key] else { return XCTFail("B invite: \(String(describing: atInvite[s.b.key]))") }
        guard case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: s.b.key, chatId: s.b.chat, inviteWire: cached) else { return XCTFail("accept") }
        postP2(accept, from: s.b, audience: s.all)
        XCTAssertNil(s.n.runtime.pairing.bindingStore.current(s.n.chat))
        let fromB = try XCTUnwrap(sendE2(s.b, "B on the new binding"))
        XCTAssertNotEqual(readE2(s.n, fromB), "B on the new binding")
        // a new code for the new binding works on N
        clock.ms += 1_000
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: s.o.key, chatId: s.o.chat) else { return XCTFail("share") }
        XCTAssertEqual(V2PairingDispatch.installJoin(accountKey: s.n.key, chatId: s.n.chat, text: share.text), .installed)
        XCTAssertEqual(readE2(s.n, fromB), "B on the new binding")
        XCTAssertEqual(e2EveryDirection(s, tag: "round2"), [])
    }

    func testBRepairsWithOAndOsAcceptSetsNAside() throws {
        guard let (s, _) = cloneScene(initiator: "O") else { return }
        clock.ms += 60_000
        pair(s.o, s.b, watchers: [s.n], initiator: s.b)
        XCTAssertNil(s.n.runtime.pairing.bindingStore.current(s.n.chat), "O's ACCEPT for B's new invite set N aside")
        XCTAssertNotNil(s.o.runtime.pairing.bindingStore.current(s.o.chat))
    }

    /// The edge PLAN.md 3.39.13 「必改项」 3 does not reach, pinned so a change is deliberate: N pairing the chat again
    /// under its OWN global identity (it accepts B's new invite) is not the clone's identity, so O cannot tell it from
    /// any other device of the account and keeps its binding — which B has left. Same on Web (`cloneSibling.ts` only
    /// acts on the shared identity).
    func testNRepairingUnderItsOwnIdentityDoesNotSetOAside() throws {
        guard let (s, _) = cloneScene() else { return }
        clock.ms += 60_000
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: s.b.key, chatId: s.b.chat, targetUser: userA) else { return XCTFail("B invite") }
        let atInvite = postP2(invite, from: s.b, audience: s.all)
        guard case let .invited(_, _, cached)? = atInvite[s.n.key] else { return XCTFail("N invite: \(String(describing: atInvite[s.n.key]))") }
        clock.ms += 1_000
        guard case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: s.n.key, chatId: s.n.chat, inviteWire: cached) else { return XCTFail("N accept") }
        let atAccept = postP2(accept, from: s.n, audience: s.all)
        // 2026-10-01: O is told the account accepted elsewhere, and the invite it was offered too is closed there
        XCTAssertEqual(atAccept[s.o.key], .ignored(reason: V2PairingDispatch.siblingAcceptedReason))
        XCTAssertNil(s.o.runtime.persisted.incomingInviteStore.get(s.o.chat))
        XCTAssertNotNil(s.o.runtime.pairing.bindingStore.current(s.o.chat), "known gap: O keeps its binding")
        let fromB = try XCTUnwrap(sendE2(s.b, "B to N"))
        XCTAssertEqual(readE2(s.n, fromB), "B to N")
    }

    // MARK: restart

    func testEverythingHoldsAcrossARestartOfEveryDevice() throws {
        guard let (s, _) = cloneScene(rekeysBefore: 1) else { return }
        clock.ms += 1_000
        guard case let .sent(rekey) = V2PairingDispatch.rekey(accountKey: s.n.key, chatId: s.n.chat) else { return XCTFail("N rekey") }
        postP2(rekey, from: s.n, audience: s.all)
        for device in s.all { restart(device) }
        XCTAssertEqual(e2EveryDirection(s, tag: "restarted"), [])
        // N's own rekey, re-rendered after the restart: still its own (the sent-event log survived)
        XCTAssertEqual(render(rekey, on: s.n, sentBy: s.n), .ignored(reason: "own_echo:roster_commit"))
        XCTAssertTrue(s.n.runtime.persisted.sentEventStore.contains(try XCTUnwrap(V2Envelope.parse(prefix: V2Messages.prefix, text: rekey)?.eventId)))
        // and O's rekey after the restart still reaches N
        clock.ms += 1_000
        guard case let .sent(again) = V2PairingDispatch.rekey(accountKey: s.o.key, chatId: s.o.chat) else { return XCTFail("O rekey") }
        postP2(again, from: s.o, audience: s.all)
        XCTAssertEqual(e2EveryDirection(s, tag: "after restart and rekey"), [])
        // the repaired-by-sibling line also survives a restart
        clock.ms += 60_000
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: s.o.key, chatId: s.o.chat, targetUser: userB) else { return XCTFail("O invite") }
        postP2(invite, from: s.o, audience: s.all)
        restart(s.n)
        XCTAssertNil(s.n.runtime.pairing.bindingStore.current(s.n.chat))
        XCTAssertEqual(render(invite, on: s.n, sentBy: s.o), .join(.cloneSiblingRepaired))
    }
}
