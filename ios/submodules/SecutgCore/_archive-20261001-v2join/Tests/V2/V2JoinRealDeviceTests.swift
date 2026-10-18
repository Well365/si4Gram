import XCTest
@testable import SecutgCore

/// PLAN.md 3.39 — the 2026-09-29 15:35 real-device run, replayed through ONLY the entry points the three runtimes call,
/// in the order they call them, with the `isOutgoing` flag Telegram gives each device and REAL asymmetric chat ids:
///
/// - O (account A, macOS) and B (account B, Android) pair through `V2PairingDispatch` exactly like the runtimes do —
///   every P2 message is seen by every device in the chat (the sender's own local copy, the sender's sibling as an
///   outgoing message, the peer as an incoming one), and every wire a `.progressed` outcome hands back is relayed by
///   the device that got it;
/// - N (account A, iOS, its own identity) is logged in the whole time and therefore sees all of that traffic too;
/// - O shows the V2Q (`prepareJoinShare`), N inspects and installs it, N sends the commit — its local copy runs the
///   commit through `handleIncoming(isOutgoing: true)` with no server date (iOS `localCopy`) and again once the server
///   has dated it (`applySentControlDate`) — O sees it as OUTGOING, B as INCOMING;
/// - then E2 in every direction, before and after a restart of every runtime.
final class V2JoinRealDeviceTests: XCTestCase {
    private let userA = "7001"
    private let userB = "8002"

    private final class Clock {
        var ms: Int64 = 1_790_100_000_000
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
        V2RuntimeRegistry.shared.set(runtime, for: key)
        // 1v1 chat ids are asymmetric: every device names the chat after the OTHER user.
        let device = Device(key: key, userId: userId, chat: userId == userA ? userB : userA, storage: storage, identity: identity, runtime: runtime)
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

    /// `sender` posts a P2 wire into the chat. Its own local copy renders first (iOS `localCopy`), then everybody else in
    /// `audience`; every `.progressed(wire)` is relayed by the device that got it (the runtimes' `v2PairingWires`).
    /// Returns every device's outcome for this message.
    @discardableResult
    private func postP2(_ wire: String, from sender: Device, audience: [Device], relay: Bool = true) -> [String: V2PairingReceiveOutcome] {
        var outcomes: [String: V2PairingReceiveOutcome] = [:]
        var next: [(Device, String)] = []
        for device in [sender] + audience.filter({ $0 !== sender }) {
            let outcome = render(wire, on: device, sentBy: sender)
            outcomes[device.key] = outcome
            if relay, case let .progressed(onward?) = outcome { next.append((device, onward)) }
        }
        for (device, onward) in next { postP2(onward, from: device, audience: audience, relay: relay) }
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

    /// O↔B pairing, B initiating (as on the devices: the Android peer invited), through the dispatch with every device of
    /// both accounts watching. B's INVITE also reaches N, which caches it like O does.
    private func pair(o: Device, b: Device, watchers: [Device], initiator: Device, file: StaticString = #filePath, line: UInt = #line) {
        let responder = initiator === o ? b : o
        let all = [o, b] + watchers
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: initiator.key, chatId: initiator.chat, targetUser: responder.userId) else {
            return XCTFail("invite", file: file, line: line)
        }
        let atInvite = postP2(invite, from: initiator, audience: all)
        let cached: String
        switch atInvite[responder.key] {
        case let .invited(_, _, wire)?: cached = wire
        case let .invitedKeyChanged(_, _, wire, _, _)?: cached = wire // PLAN.md 3.43: same cache, same accept road
        default: return XCTFail("responder did not see an invite: \(String(describing: atInvite[responder.key]))", file: file, line: line)
        }
        guard case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: responder.key, chatId: responder.chat, inviteWire: cached) else {
            return XCTFail("accept", file: file, line: line)
        }
        postP2(accept, from: responder, audience: all)
        XCTAssertEqual(V2PairingStatus.of(accountKey: o.key, chatId: o.chat).pairingState, "paired", file: file, line: line)
        XCTAssertEqual(V2PairingStatus.of(accountKey: b.key, chatId: b.chat).pairingState, "paired", file: file, line: line)
    }

    private struct Scene {
        let o: Device
        let n: Device
        let b: Device
        var all: [Device] { return [o, n, b] }
    }

    /// Everything up to (not including) N sending the commit. Returns the commit wire N's `installJoin` handed back.
    private func sceneUpToInstall(initiator: String = "B", rekeysBefore: Int = 0, file: StaticString = #filePath, line: UInt = #line) -> (Scene, String)? {
        let o = makeDevice("O", userId: userA)
        let b = makeDevice("B", userId: userB)
        let n = makeDevice("N", userId: userA)
        let scene = Scene(o: o, n: n, b: b)
        pair(o: o, b: b, watchers: [n], initiator: initiator == "B" ? b : o, file: file, line: line)
        for _ in 0..<rekeysBefore {
            guard case let .sent(rekey) = V2PairingDispatch.rekey(accountKey: o.key, chatId: o.chat) else { XCTFail("rekey", file: file, line: line); return nil }
            postP2(rekey, from: o, audience: scene.all)
        }
        // O and B were exchanging messages; N saw them and could not read them yet.
        guard let fromB = sendE2(b, "B before", file: file, line: line), let fromO = sendE2(o, "O before", file: file, line: line) else { return nil }
        XCTAssertEqual(readE2(o, fromB), "B before", file: file, line: line)
        XCTAssertEqual(readE2(b, fromO), "O before", file: file, line: line)
        XCTAssertNotEqual(readE2(n, fromB), "B before", file: file, line: line)

        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat, label: "Mac") else {
            XCTFail("share", file: file, line: line); return nil
        }
        guard case .ok = V2PairingDispatch.inspectJoin(accountKey: n.key, chatId: n.chat, text: share.text) else { XCTFail("inspect", file: file, line: line); return nil }
        guard case let .installed(commit) = V2PairingDispatch.installJoin(accountKey: n.key, chatId: n.chat, text: share.text) else {
            XCTFail("install", file: file, line: line); return nil
        }
        XCTAssertEqual(readE2(n, fromB), "B before", "N reads history once installed", file: file, line: line)
        return (scene, commit)
    }

    /// E2 in every direction; returns the failures as readable strings (empty = all good).
    private func e2EveryDirection(_ s: Scene, tag: String) -> [String] {
        var failures: [String] = []
        func check(_ from: Device, _ to: [Device]) {
            let text = "\(tag) \(from.key)"
            guard case let .sent(wire) = V2Dispatch.prepareOutgoingText(accountKey: from.key, chatId: from.chat, text: text) else {
                failures.append("\(from.key) cannot send: \(V2Dispatch.prepareOutgoingText(accountKey: from.key, chatId: from.chat, text: text))")
                return
            }
            for device in to {
                let got = readE2(device, wire)
                if got != text { failures.append("\(from.key)→\(device.key): \(got)") }
            }
        }
        check(s.b, [s.o, s.n])
        check(s.n, [s.b, s.o])
        check(s.o, [s.b, s.n])
        return failures
    }

    // MARK: the real order

    /// The run as it happened: N's local copy (no date), the server's date on N, then O (outgoing) and B (incoming).
    func testTheRealDeviceOrderEveryDeviceAdoptsAndE2WorksEverywhereAlsoAfterRestarts() throws {
        guard let (s, commit) = sceneUpToInstall() else { return }
        let atN = render(commit, on: s.n, sentBy: s.n)          // localCopy
        let atNDated = render(commit, on: s.n, sentBy: s.n)     // applySentControlDate
        let atO = render(commit, on: s.o, sentBy: s.n)
        let atB = render(commit, on: s.b, sentBy: s.n)
        guard case .join(.done) = atN else { return XCTFail("N local copy: \(atN)") }
        guard case .join(.done) = atNDated else { return XCTFail("N dated copy: \(atNDated)") }
        guard case .join(.siblingAdded) = atO else { return XCTFail("O: \(atO)") }
        guard case .join(.peerAdded) = atB else { return XCTFail("B: \(atB)") }
        XCTAssertEqual(e2EveryDirection(s, tag: "live"), [])
        for device in s.all { restart(device) }
        XCTAssertEqual(e2EveryDirection(s, tag: "restarted"), [])
    }

    func testOInitiatedPairingAndEarlierRekeysChangeNothing() throws {
        guard let (s, commit) = sceneUpToInstall(initiator: "O", rekeysBefore: 2) else { return }
        postP2(commit, from: s.n, audience: s.all)
        XCTAssertEqual(e2EveryDirection(s, tag: "live"), [])
    }

    /// Variant: N's local-copy dispatch never happens; only 〔重新发送〕 later.
    func testNsLocalCopyNeverRunsAndTheResendCompletesIt() throws {
        guard let (s, commit) = sceneUpToInstall() else { return }
        render(commit, on: s.o, sentBy: s.n)
        render(commit, on: s.b, sentBy: s.n)
        let resend = try XCTUnwrap(V2PairingDispatch.pendingJoinCommitWire(accountKey: s.n.key, chatId: s.n.chat))
        XCTAssertEqual(resend, commit)
        postP2(resend, from: s.n, audience: s.all)
        XCTAssertEqual(e2EveryDirection(s, tag: "resent"), [])
    }

    /// Variant: O's app was restarted between showing the code and receiving the commit.
    func testORestartedBetweenShowingAndReceivingTheCommit() throws {
        guard let (s, commit) = sceneUpToInstall() else { return }
        restart(s.o)
        postP2(commit, from: s.n, audience: s.all)
        XCTAssertEqual(e2EveryDirection(s, tag: "live"), [])
    }

    /// The 15:34–15:37 sequence from O's own log: an earlier round left N joined (N's E2 at 15:34:18 went out), O pressed
    /// 一键恢复 (its UNPAIR is an outgoing message N sees as a sibling's), O and B paired again, B wrote, O showed a new
    /// code and N scanned it. N must end up on the NEW binding.
    func testAfterOResetsAndRepairsNImportsTheNewBindingWhenItSawTheReset() throws {
        guard let (s, commit) = sceneUpToInstall() else { return }
        postP2(commit, from: s.n, audience: s.all)
        XCTAssertEqual(e2EveryDirection(s, tag: "round1"), [])
        // O: 一键恢复 — cancelAllForChat + unpair, every wire posted into the chat
        var resetWires = s.o.runtime.pairing.cancelAllForChat(s.o.chat)
        let unpairWire = try XCTUnwrap(s.o.runtime.pairing.unpair(s.o.chat))
        resetWires.append(unpairWire)
        s.o.runtime.persisted.persist()
        for wire in resetWires { postP2(wire, from: s.o, audience: s.all) }
        XCTAssertNil(s.n.runtime.pairing.bindingStore.current(s.n.chat), "N tore its joined binding down with O's UNPAIR")
        XCTAssertNil(s.b.runtime.pairing.bindingStore.current(s.b.chat))
        pair(o: s.o, b: s.b, watchers: [s.n], initiator: s.o)
        let fromB = try XCTUnwrap(sendE2(s.b, "B after re-pair"))
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: s.o.key, chatId: s.o.chat, label: "Mac") else { return XCTFail("share") }
        guard case let .installed(commit2) = V2PairingDispatch.installJoin(accountKey: s.n.key, chatId: s.n.chat, text: share.text) else {
            return XCTFail("install refused: \(V2PairingDispatch.installJoin(accountKey: s.n.key, chatId: s.n.chat, text: share.text))")
        }
        XCTAssertEqual(readE2(s.n, fromB), "B after re-pair")
        postP2(commit2, from: s.n, audience: s.all)
        XCTAssertEqual(e2EveryDirection(s, tag: "round2"), [])
    }

    /// THE 2026-09-29 15:34–15:37 RUN, as O's own MTProto log shows it (message ids 6019–6035, sizes in bytes): N sent an
    /// E2 at 15:34:18 (6019, 584 B) — it held a sendable binding — while O was already on a DIFFERENT binding (an earlier
    /// re-pair on the bound chat left N on the old one: nothing tells a V2Q-joined sibling that O and B moved on). O
    /// pressed 一键恢复 at 15:34:52 (6022 = UNPAIR of O's binding, 6023 = v1 U1), re-paired with B (6024–6028), B wrote
    /// (6029/6030), O showed the code, N scanned. No commit ever reached the server (N's only later messages are 6031 =
    /// E2 584 B, 6033 = UNPAIR-sized P2 600 B, 6035 = 120 B plain text; a commit is ~1.8 KB): N's import was refused
    /// `already_paired` because N still held the stale binding, which O's UNPAIR — naming O's binding, not N's — did not
    /// touch. N then E2'd under the dead binding (O: raw E2), unpaired it as the refusal told it to (O: 「已忽略…」), and
    /// was left with nothing (plain text).
    func testTheRealRunAStaleSiblingBindingIsClearedByTheAccountsResetAndTheNextImportWorks() throws {
        guard let (s, commit) = sceneUpToInstall() else { return }
        postP2(commit, from: s.n, audience: s.all)
        XCTAssertEqual(e2EveryDirection(s, tag: "round1"), [])
        let staleBindingId = try XCTUnwrap(s.n.runtime.pairing.bindingStore.current(s.n.chat)?.bindingId)

        // An earlier re-pair on the bound chat: O and B move to a new binding, N (joined by V2Q) is not part of it.
        clock.ms += 60_000
        pair(o: s.o, b: s.b, watchers: [s.n], initiator: s.o)
        let oBinding = try XCTUnwrap(s.o.runtime.pairing.bindingStore.current(s.o.chat)?.bindingId)
        XCTAssertNotEqual(oBinding, staleBindingId)
        XCTAssertEqual(s.n.runtime.pairing.bindingStore.current(s.n.chat)?.bindingId, staleBindingId, "N is left on the old binding")
        // 15:34:18 — N's E2 still goes out, under the dead binding; B, on the new binding, does not get it on that one.
        let stale = try XCTUnwrap(sendE2(s.n, "N on the dead binding"))
        XCTAssertEqual(V2E2.parse(stale)?.header.genesisOrBinding, staleBindingId)

        // 15:34:52 — O: 一键恢复 (cancelAllForChat + UNPAIR), posted into the chat; N sees it as a sibling's.
        clock.ms += 60_000
        var resetWires = s.o.runtime.pairing.cancelAllForChat(s.o.chat)
        resetWires.append(try XCTUnwrap(s.o.runtime.pairing.unpair(s.o.chat)))
        for wire in resetWires { postP2(wire, from: s.o, audience: s.all) }
        XCTAssertNil(s.n.runtime.pairing.bindingStore.current(s.n.chat), "the account's reset leaves N with no binding either")

        // 15:34:59–15:35:33 — O and B pair again, B writes.
        clock.ms += 10_000
        pair(o: s.o, b: s.b, watchers: [s.n], initiator: s.o)
        let fromB = try XCTUnwrap(sendE2(s.b, "B after the reset"))
        // ~15:36 — O shows the code, N scans it.
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: s.o.key, chatId: s.o.chat, label: "Mac") else { return XCTFail("share") }
        guard case .ok = V2PairingDispatch.inspectJoin(accountKey: s.n.key, chatId: s.n.chat, text: share.text) else {
            return XCTFail("inspect: \(V2PairingDispatch.inspectJoin(accountKey: s.n.key, chatId: s.n.chat, text: share.text))")
        }
        guard case let .installed(commit2) = V2PairingDispatch.installJoin(accountKey: s.n.key, chatId: s.n.chat, text: share.text) else {
            return XCTFail("install: \(V2PairingDispatch.installJoin(accountKey: s.n.key, chatId: s.n.chat, text: share.text))")
        }
        XCTAssertEqual(readE2(s.n, fromB), "B after the reset")
        postP2(commit2, from: s.n, audience: s.all)
        XCTAssertEqual(e2EveryDirection(s, tag: "round2"), [])
        for device in s.all { restart(device) }
        XCTAssertEqual(e2EveryDirection(s, tag: "round2 restarted"), [])
    }

    /// The superseded rule's guards: an UNPAIR naming another binding of the chat sets this device's binding aside only
    /// when a current roster member of it signed it AFTER this device installed it; a history replay from before, a
    /// signer the binding does not know, and an UNPAIR with no chat to judge it in change nothing.
    func testAnUnpairOfAnotherBindingSetsTheStaleOneAsideOnlyWhenAMemberSignedItAfterTheInstall() throws {
        guard let (s, commit) = sceneUpToInstall() else { return }
        postP2(commit, from: s.n, audience: s.all)
        let installedAt = try XCTUnwrap(s.n.runtime.pairing.bindingStore.current(s.n.chat)?.installedAtMs)
        let staleId = try XCTUnwrap(s.n.runtime.pairing.bindingStore.current(s.n.chat)?.bindingId)
        clock.ms += 60_000
        pair(o: s.o, b: s.b, watchers: [s.n], initiator: s.b)

        // made before N installed its binding: a replay, not news
        let now = clock.ms
        clock.ms = installedAt - 1
        let early = try XCTUnwrap(s.o.runtime.pairing.unpair(s.o.chat))
        clock.ms = now
        XCTAssertEqual(s.n.runtime.pairing.handleUnpair(early, localChatId: s.n.chat).reason, "stale")
        XCTAssertEqual(s.n.runtime.pairing.bindingStore.current(s.n.chat)?.bindingId, staleId)
        // no chat to judge it in: the old answer
        XCTAssertEqual(s.n.runtime.pairing.handleUnpair(early).reason, "unknown_txn")
        // a signer N's binding does not know (a stranger's identity on the same account)
        let stranger = makeDevice("X", userId: userA)
        let strangersPeer = makeDevice("Y", userId: userB)
        pair(o: stranger, b: strangersPeer, watchers: [], initiator: stranger)
        let foreign = try XCTUnwrap(stranger.runtime.pairing.unpair(stranger.chat))
        XCTAssertEqual(s.n.runtime.pairing.handleUnpair(foreign, localChatId: s.n.chat).reason, "unknown_txn")
        XCTAssertEqual(s.n.runtime.pairing.bindingStore.current(s.n.chat)?.bindingId, staleId)
        // B's own reset of the binding it moved to, made after N's install: N's stale binding is set aside, keys kept
        clock.ms += 1_000
        let fresh = try XCTUnwrap(s.b.runtime.pairing.unpair(s.b.chat))
        guard case .progressed = render(fresh, on: s.n, sentBy: s.b) else { return XCTFail("N did not take the peer's reset") }
        XCTAssertNil(s.n.runtime.pairing.bindingStore.current(s.n.chat))
        XCTAssertEqual(s.n.runtime.pairing.bindingStore.historical(s.n.chat).last?.bindingId, staleId)
        XCTAssertNotNil(s.n.runtime.pairing.tombstoneStore.unpairedFor(staleId))
    }

    /// The cross-client half of the run: B is Android. This builds the exact commit N sends and the E2 N and O send after
    /// it, together with B's state right before the commit, and — when `SECUTG_V2JOIN_ANDROID_FIXTURE` names a file —
    /// writes them out for Android's `SwiftCommitFixtureTest` (`secutg-core/src/test/resources/vectors/
    /// v2join-realdevice-swift.json`), which feeds them to Android's real dispatch as B. Without the variable it only
    /// checks that the Swift B takes the same bytes the same way.
    func testExportTheRealRunForTheAndroidPeer() throws {
        guard let (s, commit) = sceneUpToInstall() else { return }
        let bBefore = try XCTUnwrap(s.b.runtime.pairing.bindingStore.current(s.b.chat))
        let masters = s.b.runtime.pairing.keyStore.all(bBefore.bindingId).sorted { $0.epoch < $1.epoch }
        render(commit, on: s.n, sentBy: s.n)
        render(commit, on: s.o, sentBy: s.n)
        let fromN = try XCTUnwrap(sendE2(s.n, "N after the join"))
        let fromO = try XCTUnwrap(sendE2(s.o, "O after the join"))
        guard case .join(.peerAdded) = render(commit, on: s.b, sentBy: s.n) else { return XCTFail("Swift B did not adopt") }
        XCTAssertEqual(readE2(s.b, fromN), "N after the join")
        XCTAssertEqual(readE2(s.b, fromO), "O after the join")
        guard let path = ProcessInfo.processInfo.environment["SECUTG_V2JOIN_ANDROID_FIXTURE"], !path.isEmpty else { return }
        let identity = s.b.runtime.identity
        let fixture: [String: Any] = [
            "comment": "Generated by SecutgCore V2JoinRealDeviceTests.testExportTheRealRunForTheAndroidPeer (iOS/macOS). B's state before the add_device commit N sends, the commit, and E2 sent by N and O after it.",
            "b": [
                "user_id": identity.userId,
                "identity_pk": Base64Url.encode(identity.publicKey), "identity_sk": Base64Url.encode(identity.secretKey),
                "encapsulation_pk": Base64Url.encode(identity.encapsulationPk), "encapsulation_sk": Base64Url.encode(identity.encapsulationSk),
                "chat_id": s.b.chat,
            ],
            "binding": [
                "binding_id": bBefore.bindingId, "epoch": bBefore.epoch, "device_roster": bBefore.deviceRoster,
                "device_keys": bBefore.deviceKeys.mapValues { ["identity_pk": $0.identityPk, "encapsulation_pk": $0.encapsulationPk] },
                "txn_id": bBefore.txnId, "installed_at_ms": bBefore.installedAtMs,
                "masters": masters.map { ["epoch": $0.epoch, "master": Base64Url.encode($0.master ?? [])] },
            ],
            "commit_wire": commit,
            "n_device_id": try XCTUnwrap(s.n.runtime.pairing.bindingStore.current(s.n.chat)?.ownIdentity?.deviceId),
            "e2": [["from": "N", "wire": fromN, "text": "N after the join"], ["from": "O", "wire": fromO, "text": "O after the join"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Variant: the commit reaches O only after N's first E2 (N adopted from its local copy at once).
    func testTheCommitReachesOAfterNsFirstE2() throws {
        guard let (s, commit) = sceneUpToInstall() else { return }
        render(commit, on: s.n, sentBy: s.n)
        render(commit, on: s.b, sentBy: s.n)
        let early = try XCTUnwrap(sendE2(s.n, "N early"))
        let atOEarly = readE2(s.o, early)
        render(commit, on: s.o, sentBy: s.n)
        // what a re-render of the same row does once the commit is in (3.44 opens stored rows at draw time)
        let atOLater: String
        if case let .decrypted(text) = V2Dispatch.openStoredText(accountKey: s.o.key, chatId: s.o.chat, wireText: early) { atOLater = text } else { atOLater = "<failed>" }
        XCTAssertEqual(atOLater, "N early", "O reads N's early message once the commit is in (was \(atOEarly) before)")
        XCTAssertEqual(e2EveryDirection(s, tag: "live"), [])
    }
}
