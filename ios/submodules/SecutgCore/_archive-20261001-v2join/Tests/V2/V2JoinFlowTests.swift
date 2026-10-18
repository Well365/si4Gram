import XCTest
@testable import SecutgCore

/// PLAN.md 3.39.9's flow tests, through the real dispatch surface (`V2PairingDispatch` / `V2Dispatch` /
/// `V2PairingStatus`) with REAL asymmetric 1:1 chat ids (each side names the chat by the peer's user id):
/// O prepares → N installs → N "sends" the commit → O / the peer / N each adopt it → three-way E2; the expiry
/// auto-rekey; a second old device (O2) adopting as a sibling; N's send failure and retry across a restart; the
/// `dropBindingsWithoutOwnIdentity` exemption; N's unpair; an import into an already-paired chat refused; and the
/// 3.39.6 sibling rule itself.
final class V2JoinFlowTests: XCTestCase {
    private let oUser = "100"
    private let pUser = "200"
    /// O's (and every other device of O's account's) name for the chat = the peer's user id; the peer's = O's user id.
    private var oChat: String { return pUser }
    private var pChat: String { return oUser }
    private let t0: Int64 = 1_790_000_000_000

    private final class Clock {
        var ms: Int64
        init(_ ms: Int64) { self.ms = ms }
    }

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

    private let clock = Clock(1_790_000_000_000)
    private var devices: [Device] = []

    override func tearDown() {
        for device in devices { V2RuntimeRegistry.shared.reset(for: device.key) }
        devices = []
        super.tearDown()
    }

    // MARK: harness

    private func storedIdentity() -> KeyRing.Identity {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        return KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
    }

    private func makeDevice(_ key: String, userId: String, chat: String) -> Device {
        let storage = V2MemoryStorage()
        let identity = storedIdentity()
        let clock = self.clock
        let runtime = V2Runtime(identity: V2IdentityBridge.identity(userId: userId, from: identity)!, persisted: V2PersistedState.load(storage: storage), now: { clock.ms })
        V2RuntimeRegistry.shared.set(runtime, for: key)
        let device = Device(key: key, userId: userId, chat: chat, storage: storage, identity: identity, runtime: runtime)
        devices.append(device)
        return device
    }

    /// "This device restarted": a fresh runtime over what was persisted (construction runs the self-heal sweep).
    private func restart(_ device: Device) {
        device.runtime.persisted.persist()
        let clock = self.clock
        device.runtime = V2Runtime(identity: V2IdentityBridge.identity(userId: device.userId, from: device.identity)!, persisted: V2PersistedState.load(storage: device.storage), now: { clock.ms })
        V2RuntimeRegistry.shared.set(device.runtime, for: device.key)
    }

    /// One full P2 exchange between O (initiator) and the peer, through the processors, with asymmetric chat ids.
    private func pairDirect(_ o: Device, _ p: Device) {
        let invite = o.runtime.pairing.startPairing(o.chat, p.userId)!
        let accept = p.runtime.pairing.acceptInvite(invite.wire, localChatId: p.chat)
        XCTAssertEqual(accept.kind, "accept")
        let select = o.runtime.pairing.handleAccept(accept.wire!)
        XCTAssertEqual(select.kind, "select_sent")
        let confirm = p.runtime.pairing.handleSelect(select.wire!)
        XCTAssertEqual(confirm.kind, "confirm_sent")
        let ready = o.runtime.pairing.handleConfirm(confirm.wire!)
        XCTAssertEqual(ready.kind, "ready_sent")
        XCTAssertEqual(p.runtime.pairing.handleReady(ready.wire!).kind, "complete")
        XCTAssertNotNil(o.runtime.pairing.bindingStore.current(o.chat))
        XCTAssertNotNil(p.runtime.pairing.bindingStore.current(p.chat))
    }

    /// A P2 wire rendering on `device` — `isOutgoing` is Telegram's own flag: true for every message this ACCOUNT
    /// sent, from any of its devices. `sender` decides it.
    @discardableResult
    private func deliver(_ wire: String, to device: Device, from sender: Device) -> V2PairingReceiveOutcome {
        return V2PairingDispatch.handleIncoming(accountKey: device.key, chatId: device.chat, wireText: wire, isOutgoing: sender.userId == device.userId)
    }

    private func send(_ device: Device, _ text: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case let .sent(wire) = V2Dispatch.prepareOutgoingText(accountKey: device.key, chatId: device.chat, text: text) else {
            XCTFail("send failed on \(device.key)", file: file, line: line)
            return nil
        }
        return wire
    }

    private func read(_ device: Device, _ wire: String) -> String? {
        guard case let .decrypted(text) = V2Dispatch.decryptIncomingText(accountKey: device.key, chatId: device.chat, wireText: wire) else { return nil }
        return text
    }

    private func status(_ device: Device) -> V2PairingStatus {
        return V2PairingStatus.of(accountKey: device.key, chatId: device.chat)
    }

    /// O shows a code; N (same account, fresh device) scans it in the same chat. Returns the commit N must send.
    private func shareAndInstall(o: Device, n: Device, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "O phone") else {
            XCTFail("share refused", file: file, line: line)
            return nil
        }
        guard case let .installed(commitWire) = V2PairingDispatch.installJoin(accountKey: n.key, chatId: n.chat, text: share.text) else {
            XCTFail("install refused", file: file, line: line)
            return nil
        }
        return commitWire
    }

    // MARK: the happy path

    func testOPreparesNInstallsAndEveryDeviceAdoptsTheCommitThenAllThreeExchangeE2() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        let oBinding = o.runtime.pairing.bindingStore.current(o.chat)!
        // a message from before the share, which N must be able to read afterwards (it carries the current master)
        let earlier = try XCTUnwrap(send(o, "before the share"))
        XCTAssertEqual(read(p, earlier), "before the share")

        // O: nothing changes locally when the code is shown — only join_pending is written
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "O phone") else { return XCTFail("share") }
        XCTAssertTrue(share.text.hasPrefix("V2Q:"))
        XCTAssertLessThanOrEqual(share.bytes, 2331)
        XCTAssertEqual(share.ecc, .m)
        XCTAssertEqual(share.keyCount, 1)
        XCTAssertEqual(share.historyDropped, 0)
        XCTAssertEqual(share.targetEpoch, oBinding.epoch + 1)
        XCTAssertEqual(share.expiresMs, clock.ms + 10 * 60 * 1000)
        XCTAssertEqual(o.runtime.pairing.bindingStore.current(o.chat)?.epoch, oBinding.epoch)
        XCTAssertNil(o.runtime.pairing.keyStore.get(oBinding.bindingId, oBinding.epoch + 1))
        XCTAssertEqual(V2PairingDispatch.joinStatus(accountKey: o.key, chatId: o.chat)?.role, .show)
        XCTAssertEqual(o.storage.saved?.join?.pending.count, 1, "join_pending is persisted")

        // N: the manifest, then the install — readable at once, not sendable yet
        guard case let .ok(manifest) = V2PairingDispatch.inspectJoin(accountKey: n.key, chatId: n.chat, text: share.text) else { return XCTFail("inspect") }
        XCTAssertEqual(manifest.peerUserId, pUser)
        XCTAssertEqual(manifest.safetyCode, status(o).safetyCode)
        XCTAssertEqual(manifest.deviceCount, 2)
        XCTAssertEqual(manifest.historyCount, 0)
        XCTAssertEqual(manifest.sourceLabel, "O phone")
        XCTAssertNil(n.runtime.pairing.bindingStore.current(n.chat), "inspect writes nothing")
        guard case let .installed(commitWire) = V2PairingDispatch.installJoin(accountKey: n.key, chatId: n.chat, text: share.text) else { return XCTFail("install") }
        let nBinding = try XCTUnwrap(n.runtime.pairing.bindingStore.current(n.chat))
        XCTAssertEqual(nBinding.bindingId, oBinding.bindingId)
        XCTAssertEqual(nBinding.epoch, oBinding.epoch)
        XCTAssertEqual(nBinding.txnId, "join:" + oBinding.bindingId)
        XCTAssertEqual(nBinding.ownIdentity?.deviceId, share.newDeviceId)
        XCTAssertNotEqual(nBinding.ownIdentity?.identityPk, Base64Url.encode(n.runtime.identity.publicKey), "the per-binding identity is the minted one, never N's global one")
        XCTAssertEqual(nBinding.safetyCode, status(o).safetyCode)
        XCTAssertFalse(nBinding.verified)
        XCTAssertEqual(read(n, earlier), "before the share", "N reads history the moment it installs")
        XCTAssertEqual(status(n).pairingState, "invited", "pending adoption reads as waiting, not paired")
        XCTAssertFalse(n.runtime.pairing.canSend(n.chat))
        XCTAssertEqual(V2PairingDispatch.pendingJoinCommitWire(accountKey: n.key, chatId: n.chat), commitWire)
        XCTAssertEqual(V2PairingDispatch.installJoin(accountKey: n.key, chatId: n.chat, text: share.text), .refused(.alreadyPaired), "a second scan of the same code is refused")

        // The commit N sends: an OUTGOING message on O's account, actor O.
        // O: its own show echo → adopted through the ordinary handleRosterCommit, opening O's own package.
        XCTAssertEqual(deliver(commitWire, to: o, from: n), .join(.siblingAdded(deviceCode: manifest.newDeviceCode)))
        XCTAssertEqual(o.runtime.pairing.bindingStore.current(o.chat)?.epoch, oBinding.epoch + 1)
        XCTAssertEqual(o.runtime.pairing.bindingStore.current(o.chat)?.deviceRoster.count, 3)
        XCTAssertNil(V2PairingDispatch.joinStatus(accountKey: o.key, chatId: o.chat), "join_pending is complete on O")
        // the peer: zero changes — the existing add_device path, and the peer line
        XCTAssertEqual(deliver(commitWire, to: p, from: n), .join(.peerAdded(fromUser: oUser, deviceCode: manifest.newDeviceCode)))
        XCTAssertEqual(p.runtime.pairing.bindingStore.current(p.chat)?.epoch, oBinding.epoch + 1)
        XCTAssertTrue(p.runtime.pairing.bindingStore.current(p.chat)!.deviceKeys[share.newDeviceId] != nil)
        // N: outgoing, actor O ≠ N's per-binding identity → a sibling's commit, processed normally → done
        XCTAssertEqual(deliver(commitWire, to: n, from: n), .join(.done(safetyCode: status(o).safetyCode)))
        XCTAssertEqual(n.runtime.pairing.bindingStore.current(n.chat)?.epoch, oBinding.epoch + 1)
        XCTAssertNil(V2PairingDispatch.joinStatus(accountKey: n.key, chatId: n.chat))
        XCTAssertNil(V2PairingDispatch.pendingJoinCommitWire(accountKey: n.key, chatId: n.chat))
        XCTAssertEqual(status(n).pairingState, "paired")
        XCTAssertEqual(status(n).safetyCode, status(o).safetyCode, "N shows the code the QR carried")
        XCTAssertEqual(status(n).verified, false)
        XCTAssertTrue(n.runtime.pairing.canSend(n.chat))
        // a replay of the commit re-renders the same lines, installs nothing twice
        XCTAssertEqual(deliver(commitWire, to: o, from: n), .join(.siblingAdded(deviceCode: manifest.newDeviceCode)))
        XCTAssertEqual(deliver(commitWire, to: p, from: n), .join(.peerAdded(fromUser: oUser, deviceCode: manifest.newDeviceCode)))
        XCTAssertEqual(deliver(commitWire, to: n, from: n), .join(.done(safetyCode: status(o).safetyCode)))
        XCTAssertEqual(o.runtime.pairing.bindingStore.current(o.chat)?.epoch, oBinding.epoch + 1)

        // Three-way E2, both directions everywhere. N signs as the per-binding identity, which the others know.
        let fromN = try XCTUnwrap(send(n, "hello from N"))
        XCTAssertEqual(V2E2.parse(fromN)?.header.senderDevice, share.newDeviceId)
        XCTAssertEqual(read(p, fromN), "hello from N")
        XCTAssertEqual(read(o, fromN), "hello from N")
        let fromP = try XCTUnwrap(send(p, "hello from P"))
        XCTAssertEqual(read(n, fromP), "hello from P")
        XCTAssertEqual(read(o, fromP), "hello from P")
        let fromO = try XCTUnwrap(send(o, "hello from O"))
        XCTAssertEqual(read(n, fromO), "hello from O")
        XCTAssertEqual(read(p, fromO), "hello from O")
        // and N's other chats are untouched: no binding, no runtime-wide identity change
        XCTAssertEqual(n.runtime.pairing.bindingStore.allChatIdsWithCurrentBinding(), [n.chat])
        XCTAssertEqual(V2OwnIdentity.ownDeviceId(for: nil, fallback: n.runtime.identity), Base64Url.encode(V2Suite.sha256(n.identity.ed25519Pk)))
    }

    func testHistoryMastersRideAlongNewestFirstAndNCanReadEveryGeneration() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        let gen1 = try XCTUnwrap(send(o, "generation one"))
        guard case .sent(let rekey1) = V2PairingDispatch.rekey(accountKey: o.key, chatId: o.chat) else { return XCTFail("rekey") }
        XCTAssertEqual(deliver(rekey1, to: p, from: o), .progressed(wire: nil))
        let gen2 = try XCTUnwrap(send(p, "generation two"))
        guard case .sent(let rekey2) = V2PairingDispatch.rekey(accountKey: o.key, chatId: o.chat) else { return XCTFail("rekey") }
        XCTAssertEqual(deliver(rekey2, to: p, from: o), .progressed(wire: nil))
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "O") else { return XCTFail("share") }
        // The capacity rule, end to end, with the real (3.39.12 compact) payload: a two-device roster carries the
        // current master and both earlier generations inside error correction M.
        print("[v2join size] 2 devices, 3 masters: \(share.bytes) bytes at \(share.ecc.rawValue)")
        XCTAssertEqual(share.ecc, .m)
        XCTAssertLessThanOrEqual(share.bytes, 2331)
        XCTAssertEqual(share.keyCount, 3)
        XCTAssertEqual(share.historyDropped, 0)
        guard case let .ok(manifest) = V2PairingDispatch.inspectJoin(accountKey: n.key, chatId: n.chat, text: share.text) else { return XCTFail("inspect") }
        XCTAssertEqual(manifest.historyCount, 2)
        XCTAssertEqual(manifest.epoch, 3)
        guard case .installed = V2PairingDispatch.installJoin(accountKey: n.key, chatId: n.chat, text: share.text) else { return XCTFail("install") }
        let bindingId = n.runtime.pairing.bindingStore.current(n.chat)!.bindingId
        XCTAssertEqual(n.runtime.pairing.keyStore.get(bindingId, 3)?.status, .current)
        XCTAssertEqual(n.runtime.pairing.keyStore.get(bindingId, 2)?.status, .historical)
        XCTAssertEqual(n.runtime.pairing.keyStore.get(bindingId, 1)?.status, .historical)
        XCTAssertEqual(read(n, gen2), "generation two")
        XCTAssertEqual(read(n, gen1), "generation one")
    }

    func testAGapInTheHistoryEndsWhatTheCodeCarriesSinceMastersArePositional() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        pairDirect(o, p)
        for _ in 0..<3 {
            guard case .sent(let rekey) = V2PairingDispatch.rekey(accountKey: o.key, chatId: o.chat) else { return XCTFail("rekey") }
            XCTAssertEqual(deliver(rekey, to: p, from: o), .progressed(wire: nil))
        }
        let bindingId = o.runtime.pairing.bindingStore.current(o.chat)!.bindingId
        XCTAssertEqual(o.runtime.pairing.bindingStore.current(o.chat)?.epoch, 4)
        o.runtime.pairing.keyStore.remove(bindingId: bindingId, epoch: 2)
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "O") else { return XCTFail("share") }
        XCTAssertEqual(share.keyCount, 2, "generations 4 and 3 ride along; the run stops at the missing 2, so 1 stays home too")
        XCTAssertEqual(share.historyDropped, 0)
    }

    // MARK: expiry

    func testAShownCodeThatExpiresUnusedTriggersAnAutomaticRekeyThatVoidsThePreSignedCommit() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        let epoch = o.runtime.pairing.bindingStore.current(o.chat)!.epoch
        let bindingId = o.runtime.pairing.bindingStore.current(o.chat)!.bindingId
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "O") else { return XCTFail("share") }
        // nothing to sweep while the window is open
        XCTAssertTrue(V2PairingDispatch.sweepExpiredJoins(accountKey: o.key).isEmpty)
        XCTAssertEqual(o.runtime.pairing.bindingStore.current(o.chat)?.epoch, epoch)
        // N scans late (still inside its 2-minute grace) but the sweep on O already ran at expiry
        clock.ms = share.expiresMs + 1
        let rekeys = V2PairingDispatch.sweepExpiredJoins(accountKey: o.key)
        XCTAssertEqual(rekeys.count, 1)
        XCTAssertEqual(rekeys[0].chatId, o.chat)
        XCTAssertEqual(o.runtime.pairing.bindingStore.current(o.chat)?.epoch, epoch + 1)
        XCTAssertEqual(o.runtime.pairing.bindingStore.current(o.chat)?.deviceRoster.count, 2)
        XCTAssertNil(V2PairingDispatch.joinStatus(accountKey: o.key, chatId: o.chat))
        XCTAssertTrue(V2PairingDispatch.sweepExpiredJoins(accountKey: o.key).isEmpty, "idempotent")
        // O's own echo of that rekey reads as the expiry line; the peer takes it as an ordinary rekey
        XCTAssertEqual(deliver(rekeys[0].wire, to: o, from: o), .join(.expiredRekeyed))
        XCTAssertEqual(deliver(rekeys[0].wire, to: p, from: o), .progressed(wire: nil))
        XCTAssertEqual(p.runtime.pairing.bindingStore.current(p.chat)?.epoch, epoch + 1)
        // N installs anyway (the code is inside its grace) and sends the stale commit: nobody adopts it
        guard case let .installed(commitWire) = V2PairingDispatch.installJoin(accountKey: n.key, chatId: n.chat, text: share.text) else { return XCTFail("install") }
        XCTAssertEqual(deliver(commitWire, to: o, from: n), .ignored(reason: "roster_commit_stale"))
        XCTAssertEqual(o.runtime.pairing.bindingStore.current(o.chat)?.deviceRoster.count, 2)
        XCTAssertEqual(deliver(commitWire, to: p, from: n), .ignored(reason: "roster_commit_stale"))
        XCTAssertNil(p.runtime.pairing.bindingStore.current(p.chat)?.deviceKeys[share.newDeviceId])
        // N's own copy: the epoch it wants (e+1) is not e's successor any more on N either — N is at e, so it
        // installs e+1 for ITSELF... except the package under e+1 was sealed to the OLD roster. O's rekey (the
        // genuine e+1) has no package for N, so N's commit is the only e+1 N can open — and it does, but the rest
        // of the roster never did: N can read e+1 history that nobody wrote and sends nothing anybody reads.
        // What actually protects the user is the sweep on N: past the window with no adoption of the GENUINE
        // e+1 the join is demoted. Simulated here by an explicit sweep after the window.
        clock.ms = share.expiresMs + 1
        XCTAssertTrue(V2PairingDispatch.sweepExpiredJoins(accountKey: n.key).isEmpty)
        XCTAssertNil(n.runtime.pairing.bindingStore.current(n.chat), "demoted to read-only history")
        XCTAssertEqual(n.runtime.pairing.bindingStore.historical(n.chat).first?.bindingId, bindingId)
        XCTAssertNotNil(n.runtime.pairing.keyStore.get(bindingId, epoch), "masters stay: history remains readable")
        // and O's genuine e+1 rekey never reaches N's roster, so O and P go on without N
        let fromO = try XCTUnwrap(send(o, "after the expiry"))
        XCTAssertEqual(read(p, fromO), "after the expiry")
    }

    func testAJoinNIsStillWaitingOnAtExpiryIsDemotedToHistoryOnRestart() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "O") else { return XCTFail("share") }
        guard case .installed = V2PairingDispatch.installJoin(accountKey: n.key, chatId: n.chat, text: share.text) else { return XCTFail("install") }
        let bindingId = n.runtime.pairing.bindingStore.current(n.chat)!.bindingId
        // inside the window, a restart keeps the binding: dropBindingsWithoutOwnIdentity's join exemption
        restart(n)
        XCTAssertEqual(n.runtime.pairing.bindingStore.current(n.chat)?.bindingId, bindingId)
        XCTAssertEqual(n.runtime.pairing.bindingStore.current(n.chat)?.ownIdentity?.deviceId, share.newDeviceId, "ownIdentity survives the reload")
        XCTAssertEqual(V2PairingDispatch.pendingJoinCommitWire(accountKey: n.key, chatId: n.chat)?.isEmpty, false, "the commit survives for 〔重新发送〕")
        // past the window with no adoption, the restart's self-heal demotes it (exemption expired)
        clock.ms = share.expiresMs + 1
        restart(n)
        XCTAssertNil(n.runtime.pairing.bindingStore.current(n.chat))
        XCTAssertEqual(n.runtime.pairing.bindingStore.historical(n.chat).count, 1)
        XCTAssertNotNil(n.runtime.pairing.keyStore.get(bindingId, 1))
        XCTAssertEqual(status(n).pairingState, nil)
    }

    // MARK: siblings

    func testASecondOldDeviceOfTheSameAccountAdoptsTheCommitAsASiblingAndMovesUpAGeneration() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let o2 = makeDevice("O2", userId: oUser, chat: oChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        // O2 got into the roster the same way earlier (its own V2Q join), so it is a full member now
        let first = try XCTUnwrap(shareAndInstall(o: o, n: o2))
        guard case .join(.siblingAdded) = deliver(first, to: o, from: o2) else { return XCTFail("O adopts") }
        guard case .join(.peerAdded) = deliver(first, to: p, from: o2) else { return XCTFail("P adopts") }
        guard case .join(.done) = deliver(first, to: o2, from: o2) else { return XCTFail("O2 adopts") }
        let epoch = o.runtime.pairing.bindingStore.current(o.chat)!.epoch
        // a joined device can itself show a code once it is a full roster member
        guard case let .shown(o2Share) = V2PairingDispatch.prepareJoinShare(accountKey: o2.key, chatId: o2.chat, label: "O2") else { return XCTFail("O2 can share") }
        print("[v2join size] 3 devices, \(o2Share.keyCount) masters: \(o2Share.bytes) bytes at \(o2Share.ecc.rawValue)")
        XCTAssertLessThanOrEqual(o2Share.bytes, 2953)
        // now O shares to a third device N; O2 sees the commit as a sibling's (outgoing, actor O ≠ O2's identity)
        let second = try XCTUnwrap(shareAndInstall(o: o, n: n))
        guard case .join(.siblingAdded) = deliver(second, to: o2, from: n) else { return XCTFail("O2 sibling adoption") }
        XCTAssertEqual(o2.runtime.pairing.bindingStore.current(o2.chat)?.epoch, epoch + 1)
        XCTAssertEqual(o2.runtime.pairing.bindingStore.current(o2.chat)?.deviceRoster.count, 4)
        guard case .join(.siblingAdded) = deliver(second, to: o, from: n) else { return XCTFail("O adopts") }
        guard case .join(.peerAdded) = deliver(second, to: p, from: n) else { return XCTFail("P adopts") }
        guard case .join(.done) = deliver(second, to: n, from: n) else { return XCTFail("N adopts") }
        // four devices, one master: everybody reads everybody
        let fromO2 = try XCTUnwrap(send(o2, "from O2"))
        XCTAssertEqual(read(n, fromO2), "from O2")
        XCTAssertEqual(read(p, fromO2), "from O2")
        XCTAssertEqual(read(o, fromO2), "from O2")
        let fromN = try XCTUnwrap(send(n, "from N"))
        XCTAssertEqual(read(o2, fromN), "from N")
        // the O2 share above was never scanned: N's commit reached O2's target epoch, so its pending record is gone
        XCTAssertNil(V2PairingDispatch.joinStatus(accountKey: o2.key, chatId: o2.chat))
        // a FOUR-device roster (five sealed packages + four key pairs) still fits a version-40 QR in the compact
        // format of 3.39.12 — at L, and possibly with history dropped
        guard case let .shown(fourth) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "O") else { return XCTFail("4 devices") }
        print("[v2join size] 4 devices, \(fourth.keyCount) masters (\(fourth.historyDropped) dropped): \(fourth.bytes) bytes at \(fourth.ecc.rawValue)")
        XCTAssertLessThanOrEqual(fourth.bytes, 2953)
    }

    func testTheSiblingRuleOfSection3396ForEveryP2Type() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let o2 = makeDevice("O2", userId: oUser, chat: oChat)
        // O's INVITE, seen on O2 (outgoing, actor O ≠ O2): the account's own line, no state
        let invite = o.runtime.pairing.startPairing(o.chat, pUser)!
        XCTAssertEqual(deliver(invite.wire, to: o2, from: o), .ignored(reason: "sibling:invite"))
        XCTAssertEqual(V2PairingDispatch.ignoredLine(reason: "sibling:invite", wire: invite.wire), .inviteSent)
        XCTAssertNil(o2.runtime.persisted.incomingInviteStore.get(o2.chat), "never offered to accept on the sibling")
        XCTAssertNil(o2.runtime.pairing.currentTransactionForChat(o2.chat))
        // ...and on O itself the same message is the own echo it always was
        XCTAssertEqual(deliver(invite.wire, to: o, from: o), .ignored(reason: "own_echo:invite"))
        // the peer's genuine INVITE is still a real offer on both of O's devices
        let peerInvite = p.runtime.pairing.startPairing(p.chat, oUser)!
        guard case .invited = deliver(peerInvite.wire, to: o2, from: p) else { return XCTFail("a peer's invite is an offer") }
        // a sibling's ACCEPT of the peer's invite is observed (P-12), not acted on
        let o2Accept = o2.runtime.pairing.acceptInvite(peerInvite.wire, localChatId: o2.chat)
        XCTAssertEqual(o2Accept.kind, "accept")
        XCTAssertEqual(deliver(o2Accept.wire!, to: o, from: o2), .ignored(reason: "sibling:accept"))
        XCTAssertEqual(V2PairingDispatch.ignoredLine(reason: "sibling:accept", wire: o2Accept.wire!), .handshake)
        // the rest of the handshake between O2 and P, as O sees it: recognised, never processed
        let select = p.runtime.pairing.handleAccept(o2Accept.wire!)
        XCTAssertEqual(deliver(select.wire!, to: o, from: p), .failed(reason: "unexpected_phase"), "the peer's SELECT names a txn O never accepted")
        let confirm = o2.runtime.pairing.handleSelect(select.wire!)
        XCTAssertEqual(deliver(confirm.wire!, to: o, from: o2), .ignored(reason: "sibling:confirm"))
        let ready = p.runtime.pairing.handleConfirm(confirm.wire!)
        XCTAssertEqual(o2.runtime.pairing.handleReady(ready.wire!).kind, "complete")
        XCTAssertNotNil(o2.runtime.pairing.bindingStore.current(o2.chat))
        XCTAssertNil(o.runtime.pairing.bindingStore.current(o.chat), "O took no part")
        // a sibling's REKEY on a chat this device is not bound in: processed normally, refused as unknown_binding
        guard case .sent(let rekey) = V2PairingDispatch.rekey(accountKey: o2.key, chatId: o2.chat) else { return XCTFail("rekey") }
        XCTAssertEqual(deliver(rekey, to: o, from: o2), .failed(reason: "unknown_binding"))
        XCTAssertEqual(deliver(rekey, to: o2, from: o2), .ignored(reason: "own_echo:roster_commit"), "a plain own rekey echo keeps its old line")
        // a sibling's UNPAIR: processed (the binding-based fallback, O2's txn being P's) — worded as the account's own
        guard case .sent(let unpair) = V2PairingDispatch.unpair(accountKey: o2.key, chatId: o2.chat) else { return XCTFail("unpair") }
        XCTAssertEqual(deliver(unpair, to: o, from: o2), .failed(reason: "unknown_txn"), "nothing to tear down on O")
        XCTAssertEqual(deliver(unpair, to: p, from: o2), .progressed(wire: nil))
        XCTAssertNil(p.runtime.pairing.bindingStore.current(p.chat))
    }

    func testASiblingsUnpairOnABoundChatTearsThisDevicesBindingDownAndReadsAsOurOwn() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        let commit = try XCTUnwrap(shareAndInstall(o: o, n: n))
        _ = deliver(commit, to: o, from: n)
        _ = deliver(commit, to: p, from: n)
        _ = deliver(commit, to: n, from: n)
        // N unpairs: signed by its per-binding identity, no txn_id (it never ran a pairing transaction)
        guard case .sent(let unpair) = V2PairingDispatch.unpair(accountKey: n.key, chatId: n.chat) else { return XCTFail("unpair") }
        let parsed = try XCTUnwrap(V2Messages.parseUnpair(unpair))
        XCTAssertNil(parsed.envelope.txnId)
        XCTAssertEqual(parsed.envelope.actorDevice, n.runtime.pairing.bindingStore.historical(n.chat).first?.ownIdentity?.deviceId)
        XCTAssertNil(n.runtime.pairing.bindingStore.current(n.chat))
        // the peer: the binding-based fallback finds the binding by id, verifies N's roster key, tears down
        XCTAssertEqual(deliver(unpair, to: p, from: n), .progressed(wire: nil))
        XCTAssertNil(p.runtime.pairing.bindingStore.current(p.chat))
        // O: same fallback (O's own txn is the pairing's, but N's wire names none) — a sibling's unpair, own wording
        XCTAssertEqual(deliver(unpair, to: o, from: n), .ignored(reason: "own_echo:unpair"))
        XCTAssertEqual(V2PairingDispatch.ignoredLine(reason: "own_echo:unpair", wire: unpair), .unpairedByYou)
        XCTAssertNil(o.runtime.pairing.bindingStore.current(o.chat))
        // a replay is refused everywhere: the binding is tombstoned
        XCTAssertEqual(deliver(unpair, to: p, from: n), .failed(reason: "unknown_txn"))
    }

    func testTheEmergencyWipeTakesThePerBindingIdentityWithEverythingElse() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        let commit = try XCTUnwrap(shareAndInstall(o: o, n: n))
        _ = deliver(commit, to: n, from: n)
        n.runtime.persisted.persist()
        XCTAssertNotNil(n.storage.saved?.binding.current.first?.ownIdentity)
        // PLAN.md 3.16 / 3.39.7: the wipe destroys v2's whole store — the joined binding, its ownIdentity, its
        // masters, join_pending — and nothing a still-live runtime does can write them back.
        n.runtime.persisted.wipe()
        XCTAssertNil(n.storage.saved)
        n.runtime.persisted.persist()
        XCTAssertNil(n.storage.saved, "a wiped state is never written back")
        let reloaded = V2PersistedState.load(storage: n.storage)
        XCTAssertNil(reloaded.bindingStore.current(n.chat))
        XCTAssertTrue(reloaded.bindingKeyStore.allBindingIds().isEmpty)
        XCTAssertTrue(reloaded.joinStore.all().isEmpty)
    }

    func testUnpairingAJoinTheRosterNeverAdoptedIsLocalOnly() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        _ = try XCTUnwrap(shareAndInstall(o: o, n: n))
        XCTAssertEqual(V2PairingDispatch.unpair(accountKey: n.key, chatId: n.chat), .failed(reason: "not_a_member"))
        XCTAssertNil(n.runtime.pairing.bindingStore.current(n.chat), "torn down locally all the same")
        XCTAssertEqual(n.storage.saved?.binding.current.count, 0, "and persisted")
        XCTAssertEqual(status(n).pairingState, nil)
    }

    // MARK: retry, refusals

    func testTheCommitSurvivesARestartForResendUntilTheJoinIsAdopted() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        let commit = try XCTUnwrap(shareAndInstall(o: o, n: n))
        // "the send failed": nothing was delivered. After a restart the very same wire is still there to resend.
        restart(n)
        XCTAssertEqual(V2PairingDispatch.pendingJoinCommitWire(accountKey: n.key, chatId: n.chat), commit)
        XCTAssertEqual(V2PairingDispatch.joinStatus(accountKey: n.key, chatId: n.chat)?.role, .import)
        XCTAssertEqual(status(n).pairingState, "invited")
        // O restarted too: its join_pending survived, so the late echo is still recognised as the show echo
        restart(o)
        guard case .join(.siblingAdded) = deliver(commit, to: o, from: n) else { return XCTFail("O adopts after restart") }
        guard case .join(.peerAdded) = deliver(commit, to: p, from: n) else { return XCTFail("P adopts") }
        guard case .join(.done) = deliver(commit, to: n, from: n) else { return XCTFail("N adopts after restart") }
        XCTAssertNil(V2PairingDispatch.pendingJoinCommitWire(accountKey: n.key, chatId: n.chat))
        restart(n)
        XCTAssertEqual(status(n).pairingState, "paired", "adopted state survives a restart with its per-binding identity")
        XCTAssertEqual(read(p, try XCTUnwrap(send(n, "still works"))), "still works")
    }

    func testAnImportIntoAChatThisDeviceIsAlreadyPairedInIsRefusedAndSoIsTheWrongChatOrTheWrongAccount() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "O") else { return XCTFail("share") }
        // the peer, already bound in this chat, cannot import (even though the code would otherwise be wrong_chat)
        XCTAssertEqual(V2PairingDispatch.inspectJoin(accountKey: p.key, chatId: p.chat, text: share.text), .refused(.alreadyPaired))
        XCTAssertEqual(V2PairingDispatch.installJoin(accountKey: p.key, chatId: p.chat, text: share.text), .refused(.alreadyPaired))
        // O itself is bound too
        XCTAssertEqual(V2PairingDispatch.inspectJoin(accountKey: o.key, chatId: o.chat, text: share.text), .refused(.alreadyPaired))
        // N in some other chat: wrong_chat; N in the right chat but garbage: malformed; expired past the grace
        XCTAssertEqual(V2PairingDispatch.inspectJoin(accountKey: n.key, chatId: "300", text: share.text), .refused(.wrongChat))
        XCTAssertEqual(V2PairingDispatch.inspectJoin(accountKey: n.key, chatId: n.chat, text: "V2Q:nope"), .refused(.malformed))
        XCTAssertEqual(V2PairingDispatch.inspectJoin(accountKey: n.key, chatId: n.chat, text: "K1Q:" + share.text.dropFirst(4)), .refused(.malformed))
        clock.ms = share.expiresMs + 2 * 60 * 1000 + 1
        XCTAssertEqual(V2PairingDispatch.inspectJoin(accountKey: n.key, chatId: n.chat, text: share.text), .refused(.expired))
        XCTAssertNil(n.runtime.pairing.bindingStore.current(n.chat))
        // no runtime at all: fails closed
        XCTAssertEqual(V2PairingDispatch.inspectJoin(accountKey: "nobody", chatId: n.chat, text: share.text), .notOnV2)
        XCTAssertEqual(V2PairingDispatch.prepareJoinShare(accountKey: "nobody", chatId: n.chat, label: "x"), .notOnV2)
    }

    func testSharingNeedsACurrentSendableBindingThisDeviceIsAMemberOf() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        // not paired at all
        XCTAssertEqual(V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "O"), .notPaired)
        pairDirect(o, p)
        // a join not yet adopted cannot vouch for a third device
        _ = try XCTUnwrap(shareAndInstall(o: o, n: n))
        XCTAssertEqual(V2PairingDispatch.prepareJoinShare(accountKey: n.key, chatId: n.chat, label: "N"), .notPaired)
        // suspended (intent=replace pending) and mismatch both refuse; the override lets it through again
        o.runtime.pairing.bindingStore.suspend(o.chat)
        XCTAssertEqual(V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "O"), .notPaired)
        let bindingId = p.runtime.pairing.bindingStore.current(p.chat)!.bindingId
        p.runtime.pairing.bindingStore.markMismatch(chatId: p.chat, bindingId: bindingId)
        XCTAssertEqual(V2PairingDispatch.prepareJoinShare(accountKey: p.key, chatId: p.chat, label: "P"), .notPaired)
        p.runtime.pairing.bindingStore.overrideMismatch(chatId: p.chat, bindingId: bindingId)
        guard case .shown = V2PairingDispatch.prepareJoinShare(accountKey: p.key, chatId: p.chat, label: "P") else { return XCTFail("override allows sharing") }
        // an unpaired chat refuses too
        _ = p.runtime.pairing.unpair(p.chat)
        XCTAssertEqual(V2PairingDispatch.prepareJoinShare(accountKey: p.key, chatId: p.chat, label: "P"), .notPaired)
    }

    func testAJoinedDeviceRekeysUnderItsPerBindingIdentityAndEverybodyFollows() throws {
        let o = makeDevice("O", userId: oUser, chat: oChat)
        let p = makeDevice("P", userId: pUser, chat: pChat)
        let n = makeDevice("N", userId: oUser, chat: oChat)
        pairDirect(o, p)
        let commit = try XCTUnwrap(shareAndInstall(o: o, n: n))
        _ = deliver(commit, to: o, from: n)
        _ = deliver(commit, to: p, from: n)
        _ = deliver(commit, to: n, from: n)
        guard case .sent(let rekey) = V2PairingDispatch.rekey(accountKey: n.key, chatId: n.chat) else { return XCTFail("rekey") }
        XCTAssertEqual(V2Envelope.parse(prefix: "P2", text: rekey)?.actorDevice, n.runtime.pairing.bindingStore.current(n.chat)?.ownIdentity?.deviceId)
        XCTAssertEqual(deliver(rekey, to: p, from: n), .progressed(wire: nil))
        XCTAssertEqual(deliver(rekey, to: o, from: n), .progressed(wire: nil), "a sibling's rekey: processed, the ordinary rekey line")
        XCTAssertEqual(deliver(rekey, to: n, from: n), .ignored(reason: "own_echo:roster_commit"))
        let epoch = n.runtime.pairing.bindingStore.current(n.chat)!.epoch
        XCTAssertEqual(o.runtime.pairing.bindingStore.current(o.chat)?.epoch, epoch)
        XCTAssertEqual(p.runtime.pairing.bindingStore.current(p.chat)?.epoch, epoch)
        XCTAssertEqual(read(o, try XCTUnwrap(send(p, "after N's rekey"))), "after N's rekey")
        XCTAssertEqual(read(n, try XCTUnwrap(send(o, "and back"))), "and back")
    }
}
