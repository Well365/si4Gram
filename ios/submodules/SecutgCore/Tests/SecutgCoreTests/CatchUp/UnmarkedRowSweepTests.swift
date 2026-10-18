import XCTest
@testable import SecutgCore

/// 2026-10-01 真机: iPhone (account A) imported a V2Q clone code from the Mac for its chat with B; the messages the
/// Notification Service Extension had stored for that chat while the app was in the background stayed shut. The
/// extension has no secuTG runtime, so those rows carry NO meta attribute; the 3.17 sweep only re-opened rows marked
/// `.undecryptable`, and the 3.47 catch-up's first enable put its watermark above them.
///
/// This replays that on the pure layer: a "database" of rows as the iOS runtime stores them (text + meta kind or none),
/// the sweep's selection (`CatchUp.isRedecryptCandidate`) and the receive hook's v2 / v1 decrypt entries, before and
/// after the import.
final class UnmarkedRowSweepTests: XCTestCase {
    private let userA = "7101"
    private let userB = "8102"
    private var keys: [String] = []
    private var now: Int64 = 1_790_300_000_000

    override func tearDown() {
        for key in keys { V2RuntimeRegistry.shared.reset(for: key) }
        keys = []
        super.tearDown()
    }

    private struct Device {
        let key: String
        let userId: String
        /// 1v1 chat ids are asymmetric: every device names the chat after the OTHER user.
        let chat: String
    }

    /// One stored row: `meta` nil = no `SecutgTextMetaAttribute` (the extension stored it).
    private struct Row {
        var text: String
        var meta: SecutgStoredKind?
    }

    private enum SecutgStoredKind { case undecryptable, decrypted, sealed }

    private func stored(_ row: Row) -> CatchUp.StoredMeta {
        switch row.meta {
        case nil: return .unmarked
        case .undecryptable?: return .undecryptable
        case .decrypted?, .sealed?: return .other
        }
    }

    private func makeDevice(_ name: String, userId: String) -> Device {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        let identity = KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
        let key = "unmarked-" + name
        let runtime = V2Runtime(identity: V2IdentityBridge.identity(userId: userId, from: identity)!,
                                persisted: V2PersistedState.load(storage: V2MemoryStorage()), now: { [unowned self] in self.now })
        V2RuntimeRegistry.shared.set(runtime, for: key)
        keys.append(key)
        return Device(key: key, userId: userId, chat: userId == userA ? userB : userA)
    }

    /// Every P2 wire is seen by every device; `.progressed` replies are relayed.
    private func post(_ wire: String, from sender: Device, to all: [Device]) -> [String: V2PairingReceiveOutcome] {
        var outcomes: [String: V2PairingReceiveOutcome] = [:]
        var onward: [(Device, String)] = []
        for device in [sender] + all.filter({ $0.key != sender.key }) {
            let outcome = V2PairingDispatch.handleIncoming(accountKey: device.key, chatId: device.chat, wireText: wire, isOutgoing: device.userId == sender.userId)
            outcomes[device.key] = outcome
            if case let .progressed(next?) = outcome { onward.append((device, next)) }
        }
        for (device, next) in onward { _ = post(next, from: device, to: all) }
        return outcomes
    }

    /// The sweep as `secutgRedecryptChats` runs it: select, run the hook's decrypt entry, write back what opened, and
    /// give an unmarked row that still fails the hook's `.undecryptable` verdict. Returns how many opened.
    private func sweep(_ rows: inout [Row], on device: Device, e1Lookup: E1Codec.KeyLookup) -> Int {
        var opened = 0
        for index in rows.indices where CatchUp.isRedecryptCandidate(text: rows[index].text, stored: stored(rows[index])) {
            let wire = rows[index].text
            var plaintext: String?
            switch V2Dispatch.decryptIncomingText(accountKey: device.key, chatId: device.chat, wireText: wire) {
            case let .decrypted(text): plaintext = text
            case .failed: plaintext = nil
            case .notV2:
                let result = E1Codec.decrypt(wire: wire, lookup: e1Lookup)
                plaintext = result.ok ? result.text : nil
            }
            if let plaintext {
                rows[index] = Row(text: plaintext, meta: .decrypted)
                opened += 1
            } else if rows[index].meta == nil {
                rows[index].meta = .undecryptable
            }
        }
        return opened
    }

    func testRowsTheExtensionStoredWithoutMetaOpenAfterAV2QImport() throws {
        let o = makeDevice("O", userId: userA) // the Mac
        let b = makeDevice("B", userId: userB) // the Android peer
        let n = makeDevice("N", userId: userA) // the iPhone
        let all = [o, b, n]

        now += 1_000
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: b.key, chatId: b.chat, targetUser: o.userId) else { return XCTFail("invite") }
        let atInvite = post(invite, from: b, to: all)
        guard case let .invited(_, _, cached)? = atInvite[o.key] else { return XCTFail("O saw no invite: \(String(describing: atInvite[o.key]))") }
        guard case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: o.key, chatId: o.chat, inviteWire: cached) else { return XCTFail("accept") }
        _ = post(accept, from: o, to: all)
        XCTAssertEqual(V2PairingStatus.of(accountKey: o.key, chatId: o.chat).pairingState, "paired")

        // B writes while the iPhone is in the background: the extension stores the wires as they are, no meta.
        guard case let .sent(w1) = V2Dispatch.prepareOutgoingText(accountKey: b.key, chatId: b.chat, text: "B one"),
              case let .sent(w2) = V2Dispatch.prepareOutgoingText(accountKey: b.key, chatId: b.chat, text: "B two") else { return XCTFail("send") }
        let e1Key: [UInt8] = Array(repeating: 7, count: 32)
        let e1Wire = try E1Codec.encrypt(text: "v1 era", entities: nil, keyId: "k1.20260101", sessionKey: e1Key)
        let lookalike = try E1Codec.encrypt(text: "kept", entities: nil, keyId: "k1.20260101", sessionKey: e1Key)
        var rows = [
            Row(text: w1, meta: nil),
            Row(text: "plain hello", meta: nil),
            Row(text: w2, meta: nil),
            Row(text: e1Wire, meta: nil),
            // a decrypted message whose words are a wire: settled, never re-read
            Row(text: lookalike, meta: .decrypted),
        ]
        // Rendering until then: the notice, never the base64.
        XCTAssertEqual(rows.compactMap { CatchUp.unmarkedWireNotice(text: $0.text, hasSecutgMeta: $0.meta != nil) }.count, 3)

        // The old selection (undecryptable only) saw none of them — the bug.
        XCTAssertTrue(rows.filter { stored($0) == .undecryptable }.isEmpty)

        // A sweep before the import opens nothing but gives the unmarked wires their real verdict.
        XCTAssertEqual(sweep(&rows, on: n, e1Lookup: { _ in nil }), 0)
        XCTAssertEqual(rows.map { $0.meta }, [.undecryptable, nil, .undecryptable, .undecryptable, .decrypted])

        // Reset to the real-device state (the catch-up pass never reached them) and import the V2Q.
        rows[0] = Row(text: w1, meta: nil)
        rows[2] = Row(text: w2, meta: nil)
        rows[3] = Row(text: e1Wire, meta: nil)
        now += 1_000
        guard case let .shown(share) = V2PairingDispatch.prepareJoinShare(accountKey: o.key, chatId: o.chat) else { return XCTFail("share") }
        guard case .installed = V2PairingDispatch.installJoin(accountKey: n.key, chatId: n.chat, text: share.text) else { return XCTFail("install") }

        XCTAssertEqual(sweep(&rows, on: n, e1Lookup: { $0 == "k1.20260101" ? e1Key : nil }), 3)
        XCTAssertEqual(rows.map { $0.text }, ["B one", "plain hello", "B two", "v1 era", lookalike])
        XCTAssertEqual(rows.map { $0.meta }, [.decrypted, nil, .decrypted, .decrypted, .decrypted])
        // and a second sweep has nothing left to do
        XCTAssertEqual(sweep(&rows, on: n, e1Lookup: { _ in nil }), 0)
    }
}
