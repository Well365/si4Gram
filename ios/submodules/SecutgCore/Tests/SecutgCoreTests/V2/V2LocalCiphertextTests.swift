import XCTest
@testable import SecutgCore

/// PLAN.md 3.44: a v2 row (private chat or group, wire `E2:`) is kept on disk as its envelope exactly as PLAN.md 3.19
/// keeps a v1 row. These are the pure rules both Apple clients share: what counts as an envelope, which chats seal,
/// how a stored envelope is opened again once the session's cache is empty — in the same process and after a
/// restart — and what a refusal is called. The platform halves (`SecutgPersist` on iOS, `LocalCiphertext` on macOS)
/// have their own tests over the same fixture.
final class V2LocalCiphertextTests: XCTestCase {
    private var devices: [V2SealedDevice] = []

    private func device(_ userId: String, _ key: String) -> V2SealedDevice {
        let device = V2SealedDevice(userId: userId, key: key)
        devices.append(device)
        return device
    }

    override func tearDown() {
        devices.forEach { $0.forget() }
        devices = []
        super.tearDown()
    }

    private func e2(from: V2SealedDevice, chat: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let outgoing = V2Dispatch.prepareOutgoingText(accountKey: from.key, chatId: chat, text: text)
        guard case .sent(let wire) = outgoing else {
            XCTFail("expected an E2 send, got \(outgoing)", file: file, line: line)
            return ""
        }
        return wire
    }

    // MARK: what counts as an envelope

    func testAnE2WireIsAnEnvelopeByShapeAndWordsThatMerelyStartWithE2AreNot() {
        let a = device("100", "lc-A")
        let b = device("200", "lc-B")
        let chats = V2SealedFixture.pair(a, b)
        let wire = e2(from: a, chat: chats.chatA, "nine, the usual place")
        XCTAssertTrue(V2E2.isWire(wire))
        // a damaged wire is still a wire — drawn as the 3.17 notice, never as its own base64 (the `E1Format.isEncrypted` rule)
        XCTAssertTrue(V2E2.isWire(String(wire.dropLast(10))))
        for words in ["E2:", "E2: hi", "E2:not base64!", "e2:abc", "P2:abc", "E1:aab2.20260913:bm9uY2U:Y2lwaGVy", ""] {
            XCTAssertFalse(V2E2.isWire(words), words)
        }
        XCTAssertFalse(V2E2.isWire("E2:" + String(repeating: "a", count: 4096)), "longer than Telegram's limit can never be ours")
    }

    // MARK: which chats seal (rule 1)

    func testOnlyAChatThatIsOnV2ByDataSealsAndOnlyWhileTheSwitchIsOn() {
        let a = device("100", "lc-A")
        let b = device("200", "lc-B")
        XCTAssertFalse(V2Dispatch.isOnV2(accountKey: a.key, chatId: b.userId))
        XCTAssertFalse(V2Dispatch.keepsCiphertextLocally(accountKey: a.key, chatId: b.userId, localCiphertext: true))
        let chats = V2SealedFixture.pair(a, b)
        XCTAssertTrue(V2Dispatch.isOnV2(accountKey: a.key, chatId: chats.chatA))
        XCTAssertTrue(V2Dispatch.isOnV2(accountKey: b.key, chatId: chats.chatB))
        // C0: nothing is filed under either side's own user id, so neither side's Saved Messages is "on v2"
        XCTAssertFalse(V2Dispatch.isOnV2(accountKey: a.key, chatId: a.userId))
        XCTAssertFalse(V2Dispatch.isOnV2(accountKey: b.key, chatId: b.userId))
        XCTAssertTrue(V2Dispatch.keepsCiphertextLocally(accountKey: a.key, chatId: chats.chatA, localCiphertext: true))
        XCTAssertTrue(V2Dispatch.keepsCiphertextLocally(accountKey: b.key, chatId: chats.chatB, localCiphertext: true))
        // the 3.19 switch off: behaviour unchanged, the words are what is stored
        XCTAssertFalse(V2Dispatch.keepsCiphertextLocally(accountKey: a.key, chatId: chats.chatA, localCiphertext: false))
        // an account with no runtime at all
        XCTAssertFalse(V2Dispatch.keepsCiphertextLocally(accountKey: "lc-nobody", chatId: chats.chatA, localCiphertext: true))
    }

    func testAV2GroupSealsOnTheSameTerms() {
        let creator = device("100", "lc-A")
        let member = device("200", "lc-B")
        XCTAssertFalse(V2Dispatch.isOnV2(accountKey: member.key, chatId: "-1004200"))
        let group = V2SealedFixture.group(creator: creator, member: member)
        XCTAssertTrue(V2Dispatch.isOnV2(accountKey: creator.key, chatId: group))
        XCTAssertTrue(V2Dispatch.isOnV2(accountKey: member.key, chatId: group))
        XCTAssertTrue(V2Dispatch.keepsCiphertextLocally(accountKey: member.key, chatId: group, localCiphertext: true))
        XCTAssertFalse(V2Dispatch.keepsCiphertextLocally(accountKey: member.key, chatId: group, localCiphertext: false))
    }

    // MARK: opening a stored envelope again (rule 2)

    func testAStoredEnvelopeOpensAgainInTheSameProcessThatAlreadyReceivedIt() {
        let a = device("100", "lc-A")
        let b = device("200", "lc-B")
        let chats = V2SealedFixture.pair(a, b)
        let wire = e2(from: a, chat: chats.chatA, "nine, the usual place")
        // ingest: the receive hook opened it once, which is what fills `V2DataProcessor`'s replay index
        XCTAssertEqual(V2Dispatch.decryptIncomingText(accountKey: b.key, chatId: chats.chatB, wireText: wire), .decrypted(text: "nine, the usual place"))
        // draw time, cache empty: the same wire again — the replay index answers with the same words, never a refusal
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: b.key, chatId: chats.chatB, wireText: wire), .decrypted(text: "nine, the usual place"))
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: b.key, chatId: chats.chatB, wireText: wire), .decrypted(text: "nine, the usual place"), "and again")
        // the sender's own sealed copy opens on the sender's screen too
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: a.key, chatId: chats.chatA, wireText: wire), .decrypted(text: "nine, the usual place"))
        // and nothing that is not an E2 is ever claimed
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: b.key, chatId: chats.chatB, wireText: "E1:aab2.20260913:bm9uY2U:Y2lwaGVy"), .notV2)
    }

    func testAStoredEnvelopeOpensAgainAfterARestartWhenNothingIsCachedAnywhere() {
        let a = device("100", "lc-A")
        let b = device("200", "lc-B")
        let chats = V2SealedFixture.pair(a, b)
        let wire = e2(from: a, chat: chats.chatA, "nine, the usual place")
        XCTAssertEqual(V2Dispatch.decryptIncomingText(accountKey: b.key, chatId: chats.chatB, wireText: wire), .decrypted(text: "nine, the usual place"))
        // a fresh process: a new runtime over the persisted state, an empty replay index, no plaintext cache
        b.restart()
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: b.key, chatId: chats.chatB, wireText: wire), .decrypted(text: "nine, the usual place"))
        // opening at draw time leaves the replay guard whole: the same wire arriving once more through the receive
        // hook is still recognised as the same message, not installed twice
        XCTAssertEqual(b.runtime.privateMessaging.receive(wire, localChatId: chats.chatB).kind, "duplicate")
        // the sender's side restarts too: its own sent copy is stored sealed and must read back on its own screen
        a.restart()
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: a.key, chatId: chats.chatA, wireText: wire), .decrypted(text: "nine, the usual place"))
    }

    func testAGroupsStoredEnvelopeOpensAgainForEveryMemberAfterARestart() {
        let creator = device("100", "lc-A")
        let member = device("200", "lc-B")
        let group = V2SealedFixture.group(creator: creator, member: member)
        let wire = e2(from: creator, chat: group, "hello group")
        XCTAssertEqual(V2Dispatch.decryptIncomingText(accountKey: member.key, chatId: group, wireText: wire), .decrypted(text: "hello group"))
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: member.key, chatId: group, wireText: wire), .decrypted(text: "hello group"))
        member.restart()
        creator.restart()
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: member.key, chatId: group, wireText: wire), .decrypted(text: "hello group"))
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: creator.key, chatId: group, wireText: wire), .decrypted(text: "hello group"))
        // the other direction, after the restart
        let reply = e2(from: member, chat: group, "hello back")
        XCTAssertEqual(V2Dispatch.decryptIncomingText(accountKey: creator.key, chatId: group, wireText: reply), .decrypted(text: "hello back"))
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: creator.key, chatId: group, wireText: reply), .decrypted(text: "hello back"))
    }

    // MARK: a refusal is a situation, never a code and never base64 (rule 2 / PLAN.md 3.17)

    func testARowWhoseBindingIsNotHereReadsAsNoKeyNeverAsItsOwnBase64() {
        let a = device("100", "lc-A")
        let b = device("200", "lc-B")
        let c = device("300", "lc-C")
        let chats = V2SealedFixture.pair(a, b)
        let wire = e2(from: a, chat: chats.chatA, "nine, the usual place")
        // a device that was never bound to this chat
        let stranger = V2Dispatch.openStoredText(accountKey: c.key, chatId: a.userId, wireText: wire)
        guard case .failed(let reason) = stranger else { return XCTFail("expected a refusal, got \(stranger)") }
        XCTAssertEqual(V2Dispatch.storedFailureDetail(reason: reason), DecryptResult.Reason.unknownKey.rawValue)
        // no runtime yet for the account: a momentary state, and the line for it says "unlocking", not "no key"
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: "lc-nobody", chatId: chats.chatB, wireText: wire), .failed(reason: "v2_not_ready"))
        XCTAssertEqual(V2Dispatch.storedFailureDetail(reason: "v2_not_ready"), "not_ready")
    }

    func testATamperedEnvelopeReadsAsPossiblyAltered() {
        let a = device("100", "lc-A")
        let b = device("200", "lc-B")
        let chats = V2SealedFixture.pair(a, b)
        let wire = e2(from: a, chat: chats.chatA, "nine, the usual place")
        // one character of the body changed: still the shape of a wire, no longer the message that was signed
        var chars = Array(wire)
        let index = chars.count - 5
        chars[index] = chars[index] == "A" ? "B" : "A"
        let tampered = String(chars)
        XCTAssertTrue(V2E2.isWire(tampered))
        let outcome = V2Dispatch.openStoredText(accountKey: b.key, chatId: chats.chatB, wireText: tampered)
        guard case .failed(let reason) = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        let detail = V2Dispatch.storedFailureDetail(reason: reason)
        XCTAssertTrue(detail == DecryptResult.Reason.authFailed.rawValue || detail == DecryptResult.Reason.malformed.rawValue, "\(reason) → \(detail)")
    }

    func testEveryV2ReasonMapsOntoTheThreeSituationsTheNoticeKnows() {
        XCTAssertEqual(V2Dispatch.storedFailureDetail(reason: "v2_not_ready"), "not_ready")
        for tampered in ["bad_signature", "decrypt_failed", "sender_not_in_roster"] {
            XCTAssertEqual(V2Dispatch.storedFailureDetail(reason: tampered), "auth_failed", tampered)
        }
        for malformed in ["malformed", "malformed_utf8", "malformed_sender_key", "malformed_binding", "malformed_state"] {
            XCTAssertEqual(V2Dispatch.storedFailureDetail(reason: malformed), "malformed", malformed)
        }
        for noKey in ["unknown_binding", "unknown_sender", "missing_key", "unknown_state", "unknown", "some_future_reason"] {
            XCTAssertEqual(V2Dispatch.storedFailureDetail(reason: noKey), "unknown_key", noKey)
        }
    }
}
