import XCTest
@testable import SecutgCore

/// PLAN.md 3.44 harness: real v2 devices, bound and grouped through the real processors — nothing forged. Each
/// device is registered in `V2RuntimeRegistry` under its own account key over its own `V2MemoryStorage`, so a test
/// can build a SECOND runtime from the same storage (what a restart leaves behind: a fresh `V2DataProcessor` with an
/// empty replay index, and no plaintext cache anywhere) and ask it to open what the first one stored.
///
/// 1:1 chat ids are asymmetric, as real clients name them (fix C0): each side calls the chat after the OTHER user.
final class V2SealedDevice {
    let key: String
    let userId: String
    let identity: V2Identity
    let storage = V2MemoryStorage()
    private(set) var runtime: V2Runtime

    init(userId: String, key: String) {
        self.key = key
        self.userId = userId
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        identity = V2Identity(userId: userId, publicKey: ed.publicKey, secretKey: ed.secretKey, encapsulationPk: x.publicKey, encapsulationSk: x.secretKey)
        runtime = V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: storage))
        V2RuntimeRegistry.shared.set(runtime, for: key)
    }

    /// What a relaunch does: a fresh runtime over the state the previous one persisted, under the same account key.
    func restart() {
        runtime = V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: storage))
        V2RuntimeRegistry.shared.set(runtime, for: key)
    }

    func forget() {
        V2RuntimeRegistry.shared.reset(for: key)
    }
}

enum V2SealedFixture {
    /// Binds `a` and `b` on one real 1:1 chat through the real pairing dispatch — A invites, B accepts, every
    /// automatic reply is carried to the other side until nothing is in flight. Returns each side's own chat id.
    @discardableResult
    static func pair(_ a: V2SealedDevice, _ b: V2SealedDevice, file: StaticString = #filePath, line: UInt = #line) -> (chatA: String, chatB: String) {
        let chatA = b.userId
        let chatB = a.userId
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: a.key, chatId: chatA, targetUser: b.userId) else {
            XCTFail("startPairing did not send", file: file, line: line)
            return (chatA, chatB)
        }
        let offered = V2PairingDispatch.handleIncoming(accountKey: b.key, chatId: chatB, wireText: invite, isOutgoing: false)
        guard case .invited(_, _, let cached) = offered else {
            XCTFail("expected .invited, got \(offered)", file: file, line: line)
            return (chatA, chatB)
        }
        guard case .sent(let accept) = V2PairingDispatch.acceptInvite(accountKey: b.key, chatId: chatB, inviteWire: cached) else {
            XCTFail("acceptInvite did not send", file: file, line: line)
            return (chatA, chatB)
        }
        var queue: [(to: V2SealedDevice, chat: String, wire: String)] = [(a, chatA, accept)]
        var hops = 0
        while !queue.isEmpty {
            hops += 1
            guard hops < 20 else {
                XCTFail("the exchange never settled", file: file, line: line)
                break
            }
            let next = queue.removeFirst()
            if case .progressed(let reply?) = V2PairingDispatch.handleIncoming(accountKey: next.to.key, chatId: next.chat, wireText: next.wire, isOutgoing: false) {
                queue.append(next.to === a ? (b, chatB, reply) : (a, chatA, reply))
            }
        }
        XCTAssertNotNil(a.runtime.pairing.bindingStore.current(chatA), "A must be bound under its own chat id", file: file, line: line)
        XCTAssertNotNil(b.runtime.pairing.bindingStore.current(chatB), "B must be bound under its own chat id", file: file, line: line)
        return (chatA, chatB)
    }

    /// A v2 group in auto mode with `creator` and `member`, through the real group processors. Returns the group's
    /// chat id — negative, as a group's is: that sign is how `V2Dispatch` tells a group from a private chat.
    @discardableResult
    static func group(_ groupId: String = "-1004200", creator: V2SealedDevice, member: V2SealedDevice, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let genesis = creator.runtime.group.genesis(groupId, mode: .auto) else {
            XCTFail("genesis failed", file: file, line: line)
            return groupId
        }
        XCTAssertTrue(member.runtime.group.handleGenesis(genesis.wire), file: file, line: line)
        guard let request = member.runtime.group.joinRequest(groupId) else {
            XCTFail("joinRequest failed", file: file, line: line)
            return groupId
        }
        let joined = creator.runtime.group.handleJoinRequest(request, master: genesis.master)
        XCTAssertTrue(joined.ok, "join refused: \(joined.reason ?? "-")", file: file, line: line)
        guard let welcome = joined.welcomeWire else {
            XCTFail("no welcome was issued", file: file, line: line)
            return groupId
        }
        XCTAssertTrue(member.runtime.group.handleWelcome(welcome).ok, file: file, line: line)
        // persisted the way a real client persists after every dispatch, so a restart finds the group
        creator.runtime.persisted.persist()
        member.runtime.persisted.persist()
        XCTAssertNotNil(creator.runtime.persisted.groupStateStore.current(groupId), file: file, line: line)
        XCTAssertNotNil(member.runtime.persisted.groupStateStore.current(groupId), file: file, line: line)
        return groupId
    }
}
