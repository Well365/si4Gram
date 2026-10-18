import XCTest
@testable import SecutgCore

/// Ported from Android's `DataProcessorTest.java` — no TEST_MATRIX.md section exists for DATA-01,
/// cases derived from v1.4 section 15/16/28's own text.
final class V2DataProcessorTests: XCTestCase {
    private let master = [UInt8](repeating: 7, count: 32)
    private let salt = [UInt8](repeating: 9, count: 32)
    private let genesisOrBinding = [UInt8](repeating: 3, count: 32)
    private let plaintext = V2Suite.utf8("hello from DataProcessor")
    private var sender: V2Suite.KeyPair!
    private var other: V2Suite.KeyPair!

    override func setUp() {
        super.setUp()
        sender = V2Suite.generateEd25519()
        other = V2Suite.generateEd25519()
    }

    private func baseSendParams(chatId: String = "chat-4200", epoch: String = "3", retryMsgId: String? = nil) -> V2DataProcessor.SendParams {
        return V2DataProcessor.SendParams(chatId: chatId, genesisOrBinding: Base64Url.encode(genesisOrBinding), epoch: epoch, saltStateOrBindingHash: salt, master: master, senderIdentityPk: sender.publicKey, senderIdentitySk: sender.secretKey, permitHash: nil, plaintext: plaintext, retryMsgId: retryMsgId)
    }

    private func receiveParams(_ dedupStateKey: String = "state-a") -> V2DataProcessor.ReceiveParams {
        return V2DataProcessor.ReceiveParams(master: master, saltStateOrBindingHash: salt, senderIdentityPk: sender.publicKey, dedupStateKey: dedupStateKey)
    }

    func testAFreshSendProducesAWireTheReceivingSideCanVerifyAndDecrypt() {
        let senderProc = V2DataProcessor()
        let receiverProc = V2DataProcessor()
        let outcome = senderProc.send(baseSendParams())
        XCTAssertNotNil(outcome)

        let received = receiverProc.receive(outcome!.wire, receiveParams())
        XCTAssertTrue(received.ok)
        XCTAssertEqual(received.kind, "installed")
        XCTAssertEqual(received.plaintext, plaintext)
        XCTAssertEqual(received.header?.seq, "1")
    }

    func testSeqIncrementsPerChatAndEpochAndResetsOnANewEpoch() {
        let senderProc = V2DataProcessor()
        let first = senderProc.send(baseSendParams(epoch: "3"))!
        let second = senderProc.send(baseSendParams(epoch: "3"))!
        let thirdDifferentEpoch = senderProc.send(baseSendParams(epoch: "4"))!

        let receiverProc = V2DataProcessor()
        XCTAssertEqual(receiverProc.receive(first.wire, receiveParams()).header?.seq, "1")
        XCTAssertEqual(receiverProc.receive(second.wire, receiveParams()).header?.seq, "2")
        XCTAssertEqual(receiverProc.receive(thirdDifferentEpoch.wire, receiveParams()).header?.seq, "1")
    }

    func testRetryingWithTheReturnedMsgIdReproducesTheIdenticalWire() {
        let senderProc = V2DataProcessor()
        let first = senderProc.send(baseSendParams())!
        let retry = senderProc.send(baseSendParams(retryMsgId: first.msgId))
        XCTAssertEqual(first.wire, retry?.wire)
        XCTAssertEqual(first.msgId, retry?.msgId)
    }

    func testRetryingDoesNotAdvanceSeqForTheNextGenuinelyNewMessage() {
        let senderProc = V2DataProcessor()
        let first = senderProc.send(baseSendParams())!
        _ = senderProc.send(baseSendParams(retryMsgId: first.msgId))
        _ = senderProc.send(baseSendParams(retryMsgId: first.msgId))
        let second = senderProc.send(baseSendParams())!

        let receiverProc = V2DataProcessor()
        XCTAssertEqual(receiverProc.receive(second.wire, receiveParams()).header?.seq, "2")
    }

    func testRetryingAnUnknownMsgIdIsRefusedNotSilentlyBuiltFresh() {
        let senderProc = V2DataProcessor()
        _ = senderProc.send(baseSendParams(chatId: "chat-A"))
        XCTAssertNil(senderProc.send(baseSendParams(chatId: "chat-A", retryMsgId: Base64Url.encode(V2Suite.randomBytes(16)))))

        let realOutcome = senderProc.send(baseSendParams(chatId: "chat-A"))!
        XCTAssertNil(senderProc.send(baseSendParams(chatId: "chat-B", retryMsgId: realOutcome.msgId)))
    }

    func testARepeatedDeliveryOfTheSameWireReturnsTheCachedResultIdempotently() {
        let senderProc = V2DataProcessor()
        let receiverProc = V2DataProcessor()
        let outcome = senderProc.send(baseSendParams())!

        let first = receiverProc.receive(outcome.wire, receiveParams())
        let second = receiverProc.receive(outcome.wire, receiveParams())
        XCTAssertTrue(first.ok)
        XCTAssertEqual(first.kind, "installed")
        XCTAssertTrue(second.ok)
        XCTAssertEqual(second.kind, "duplicate")
        XCTAssertEqual(first.plaintext, second.plaintext)
    }

    func testDedupShortCircuitsBeforeReVerifyingARepeatSucceedsEvenWithGarbageVerificationInputs() {
        let senderProc = V2DataProcessor()
        let receiverProc = V2DataProcessor()
        let outcome = senderProc.send(baseSendParams())!
        _ = receiverProc.receive(outcome.wire, receiveParams())

        let repeatWithWrongMaster = receiverProc.receive(outcome.wire, V2DataProcessor.ReceiveParams(master: [UInt8](repeating: 99, count: 32), saltStateOrBindingHash: salt, senderIdentityPk: sender.publicKey, dedupStateKey: "state-a"))
        XCTAssertTrue(repeatWithWrongMaster.ok)
        XCTAssertEqual(repeatWithWrongMaster.kind, "duplicate")
    }

    func testDifferentDedupStateKeyValuesNeverCollideEvenForTheSameSenderAndMsgId() {
        let senderProc = V2DataProcessor()
        let receiverProc = V2DataProcessor()
        let outcome = senderProc.send(baseSendParams())!
        let first = receiverProc.receive(outcome.wire, receiveParams("state-a"))
        let secondDifferentState = receiverProc.receive(outcome.wire, receiveParams("state-b"))
        XCTAssertEqual(first.kind, "installed")
        XCTAssertEqual(secondDifferentState.kind, "installed") // NOT duplicate
    }

    func testAFailedVerificationAttemptNeverPollutesTheDedupIndexForALaterGenuinelyValidDelivery() {
        let senderProc = V2DataProcessor()
        let receiverProc = V2DataProcessor()
        let outcome = senderProc.send(baseSendParams())!

        let wrongSigAttempt = receiverProc.receive(outcome.wire, V2DataProcessor.ReceiveParams(master: master, saltStateOrBindingHash: salt, senderIdentityPk: other.publicKey, dedupStateKey: "state-a"))
        XCTAssertFalse(wrongSigAttempt.ok)
        XCTAssertEqual(wrongSigAttempt.reason, "bad_signature")

        let genuineDelivery = receiverProc.receive(outcome.wire, receiveParams())
        XCTAssertTrue(genuineDelivery.ok)
        XCTAssertEqual(genuineDelivery.kind, "installed")
    }

    func testALowerSeqMessageArrivingAfterAHigherSeqOneIsAcceptedNotRejectedAsStale() {
        let senderProc = V2DataProcessor()
        let receiverProc = V2DataProcessor()
        let earlier = senderProc.send(baseSendParams())! // seq 1
        let later = senderProc.send(baseSendParams())! // seq 2

        let laterResult = receiverProc.receive(later.wire, receiveParams())
        let earlierResult = receiverProc.receive(earlier.wire, receiveParams())
        XCTAssertEqual(laterResult.kind, "installed")
        XCTAssertEqual(earlierResult.kind, "installed")
    }
}
