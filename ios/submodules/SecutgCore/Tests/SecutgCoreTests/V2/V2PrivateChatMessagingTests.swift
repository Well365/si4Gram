import XCTest
@testable import SecutgCore

/// Ported from Android's `PrivateChatMessagingTest.java` — integration coverage wiring
/// V2DataProcessor to a real V2Processor.PairingProcessor/V2Roster.RosterProcessor pair.
final class V2PrivateChatMessagingTests: XCTestCase {
    private let chat = "4200"

    private func makeIdentity(_ userId: String) -> V2Identity {
        let ed = V2Suite.generateEd25519()
        let enc = V2Suite.generateX25519()
        return V2Identity(userId: userId, publicKey: ed.publicKey, secretKey: ed.secretKey, encapsulationPk: enc.publicKey, encapsulationSk: enc.secretKey)
    }

    private func pairFully(_ a: V2Processor.PairingProcessor, _ b: V2Processor.PairingProcessor) {
        let invite = a.startPairing(chat, "200")!
        let accept = b.acceptInvite(invite.wire)
        precondition(accept.kind == "accept", "setup")
        let afterAccept = a.handleAccept(accept.wire!)
        precondition(afterAccept.ok && afterAccept.kind == "select_sent", "setup")
        let afterSelect = b.handleSelect(afterAccept.wire!)
        precondition(afterSelect.ok && afterSelect.kind == "confirm_sent", "setup")
        let afterConfirm = a.handleConfirm(afterSelect.wire!)
        precondition(afterConfirm.ok && afterConfirm.kind == "ready_sent", "setup")
        let complete = b.handleReady(afterConfirm.wire!)
        precondition(complete.ok && complete.kind == "complete", "setup")
    }

    func testAFreshPairingProducesAWorkingSendReceiveChannelBothWays() {
        let aIdentity = makeIdentity("100")
        let bIdentity = makeIdentity("200")
        let a = V2Processor.PairingProcessor(identity: aIdentity)
        let b = V2Processor.PairingProcessor(identity: bIdentity)
        pairFully(a, b)

        let sharedE2 = V2DataProcessor() // stand-in for one shared transport; each device really has its own
        let aMessaging = V2PrivateChatMessaging(identity: aIdentity, pairing: a, e2: sharedE2)
        let bMessaging = V2PrivateChatMessaging(identity: bIdentity, pairing: b, e2: sharedE2)

        let plaintext = V2Suite.utf8("hello from A")
        let sent = aMessaging.send(chat, plaintext: plaintext)
        XCTAssertTrue(sent.ok)

        let received = bMessaging.receive(sent.wire!)
        XCTAssertTrue(received.ok)
        XCTAssertEqual(received.kind, "installed")
        XCTAssertEqual(received.plaintext, plaintext)
    }

    func testCanSendAndSendRefuseBeforeAnyPairingExistsAndAfterUnpair() {
        let aIdentity = makeIdentity("100")
        let a = V2Processor.PairingProcessor(identity: aIdentity)
        let messaging = V2PrivateChatMessaging(identity: aIdentity, pairing: a, e2: V2DataProcessor())
        XCTAssertFalse(a.canSend(chat))
        let beforePairing = messaging.send(chat, plaintext: V2Suite.utf8("x"))
        XCTAssertFalse(beforePairing.ok)
        XCTAssertEqual(beforePairing.reason, "no_binding")

        let bIdentity = makeIdentity("200")
        let b = V2Processor.PairingProcessor(identity: bIdentity)
        pairFully(a, b)
        XCTAssertTrue(messaging.send(chat, plaintext: V2Suite.utf8("x")).ok)

        _ = a.unpair(chat)
        let afterUnpair = messaging.send(chat, plaintext: V2Suite.utf8("x"))
        XCTAssertFalse(afterUnpair.ok)
        XCTAssertEqual(afterUnpair.reason, "no_binding")
    }

    func testARekeyRotatesTheSaltMasterTheWiringResolvesARecipientWhoNeverCaughtUpCannotDecrypt() {
        let aIdentity = makeIdentity("100")
        let bIdentity = makeIdentity("200")
        let a = V2Processor.PairingProcessor(identity: aIdentity)
        let b = V2Processor.PairingProcessor(identity: bIdentity)
        pairFully(a, b)
        let rosterA = V2Roster.RosterProcessor(identity: aIdentity, bindingStore: a.bindingStore, tombstoneStore: a.tombstoneStore, keyStore: a.keyStore)
        let rosterB = V2Roster.RosterProcessor(identity: bIdentity, bindingStore: b.bindingStore, tombstoneStore: b.tombstoneStore, keyStore: b.keyStore)

        let rekeyWire = rosterA.rekey(chat)
        let currentA = a.bindingStore.current(chat)!
        XCTAssertEqual(a.keyStore.get(currentA.bindingId, currentA.epoch)?.status, .current)

        let aMessaging = V2PrivateChatMessaging(identity: aIdentity, pairing: a, e2: V2DataProcessor())
        let plaintext = V2Suite.utf8("post-rekey message")
        let sent = aMessaging.send(chat, plaintext: plaintext)
        XCTAssertTrue(sent.ok)

        let bMessaging = V2PrivateChatMessaging(identity: bIdentity, pairing: b, e2: V2DataProcessor())
        let beforeCatchUp = bMessaging.receive(sent.wire!)
        XCTAssertFalse(beforeCatchUp.ok)
        XCTAssertEqual(beforeCatchUp.reason, "missing_key")

        _ = rosterB.handleRosterCommit(rekeyWire!)
        let afterCatchUp = bMessaging.receive(sent.wire!)
        XCTAssertTrue(afterCatchUp.ok)
        XCTAssertEqual(afterCatchUp.kind, "installed")
    }

    func testRetryingASendReproducesTheIdenticalWire() {
        let aIdentity = makeIdentity("100")
        let bIdentity = makeIdentity("200")
        let a = V2Processor.PairingProcessor(identity: aIdentity)
        let b = V2Processor.PairingProcessor(identity: bIdentity)
        pairFully(a, b)
        let messaging = V2PrivateChatMessaging(identity: aIdentity, pairing: a, e2: V2DataProcessor())

        let first = messaging.send(chat, plaintext: V2Suite.utf8("retry me"))
        let retry = messaging.send(chat, plaintext: V2Suite.utf8("retry me"), retryMsgId: first.msgId)
        XCTAssertEqual(first.wire, retry.wire)
        XCTAssertEqual(first.msgId, retry.msgId)
    }
}
