import XCTest
@testable import SecutgCore

/// Ported from Android's `GroupMessagingTest.java` — integration coverage wiring V2DataProcessor to a
/// real V2GroupProcessor.
final class V2GroupMessagingTests: XCTestCase {
    private let group = "g-4200"

    private func makeIdentity(_ userId: String) -> V2Identity {
        let ed = V2Suite.generateEd25519()
        let enc = V2Suite.generateX25519()
        return V2Identity(userId: userId, publicKey: ed.publicKey, secretKey: ed.secretKey, encapsulationPk: enc.publicKey, encapsulationSk: enc.secretKey)
    }

    private final class Setup {
        let creatorIdentity: V2Identity
        let memberIdentity: V2Identity
        let creator: V2GroupProcessor
        let member: V2GroupProcessor

        init(mode: V2GroupState.Mode, group: String, makeIdentity: (String) -> V2Identity) {
            creatorIdentity = makeIdentity("100")
            memberIdentity = makeIdentity("200")
            creator = V2GroupProcessor(identity: creatorIdentity)
            let genesisOutcome = creator.genesis(group, mode: mode)!
            member = V2GroupProcessor(identity: memberIdentity)
            member.handleGenesis(genesisOutcome.wire)
            let joinOutcome = creator.handleJoinRequest(member.joinRequest(group)!, master: genesisOutcome.master)
            precondition(joinOutcome.ok, "setup")
            let welcomeOutcome = member.handleWelcome(joinOutcome.welcomeWire!)
            precondition(welcomeOutcome.ok, "setup")
        }
    }

    private func makeSetup(mode: V2GroupState.Mode) -> Setup {
        return Setup(mode: mode, group: group, makeIdentity: makeIdentity)
    }

    func testAFreshJoinProducesAWorkingSendReceiveChannelBothWays() {
        let s = makeSetup(mode: .auto)
        let creatorMessaging = V2GroupMessaging(identity: s.creatorIdentity, group: s.creator, e2: V2DataProcessor())
        let memberMessaging = V2GroupMessaging(identity: s.memberIdentity, group: s.member, e2: V2DataProcessor())

        let plaintext = V2Suite.utf8("hello group")
        let sent = creatorMessaging.send(group, plaintext: plaintext)
        XCTAssertTrue(sent.ok)

        let received = memberMessaging.receive(sent.wire!)
        XCTAssertTrue(received.ok)
        XCTAssertEqual(received.kind, "installed")
        XCTAssertEqual(received.plaintext, plaintext)
    }

    func testARekeyRotatesTheSaltMasterTheWiringResolvesARecipientWhoNeverCaughtUpCannotDecrypt() {
        let s = makeSetup(mode: .auto)
        let rekeyOutcome = s.creator.commit(group, reason: "rotate")!
        s.creator.handleCommit(rekeyOutcome.commitWire, transportDate: 1_000)
        let creatorResolved = s.creator.resolveCommits(group)
        XCTAssertTrue(creatorResolved.ok)

        let creatorMessaging = V2GroupMessaging(identity: s.creatorIdentity, group: s.creator, e2: V2DataProcessor())
        let sent = creatorMessaging.send(group, plaintext: V2Suite.utf8("post-rekey"))
        XCTAssertTrue(sent.ok)

        let memberMessaging = V2GroupMessaging(identity: s.memberIdentity, group: s.member, e2: V2DataProcessor())
        let beforeCatchUp = memberMessaging.receive(sent.wire!)
        XCTAssertFalse(beforeCatchUp.ok)
        XCTAssertEqual(beforeCatchUp.reason, "unknown_state")

        s.member.handleCommit(rekeyOutcome.commitWire, transportDate: 1_000)
        let memberResolved = s.member.resolveCommits(group)
        XCTAssertTrue(memberResolved.ok)
        let afterCatchUp = memberMessaging.receive(sent.wire!)
        XCTAssertTrue(afterCatchUp.ok)
        XCTAssertEqual(afterCatchUp.kind, "installed")
    }

    func testManualModeSendingNeedsTheWelcomeInstalledNotJustTheStateChainCaughtUp() {
        let s = makeSetup(mode: .manual)
        let rekeyOutcome = s.creator.commit(group, reason: "rotate")!
        s.creator.handleCommit(rekeyOutcome.commitWire, transportDate: 1_000)
        XCTAssertTrue(s.creator.resolveCommits(group).ok)
        s.member.handleCommit(rekeyOutcome.commitWire, transportDate: 1_000)
        XCTAssertTrue(s.member.resolveCommits(group).ok)

        let creatorMessaging = V2GroupMessaging(identity: s.creatorIdentity, group: s.creator, e2: V2DataProcessor())
        let preWelcomeSend = creatorMessaging.send(group, plaintext: V2Suite.utf8("x"))
        XCTAssertFalse(preWelcomeSend.ok)
        XCTAssertEqual(preWelcomeSend.reason, "cannot_send")

        let welcomes = s.creator.issueRekeyWelcomes(groupId: group, master: rekeyOutcome.master)!
        for wire in welcomes {
            s.creator.handleWelcome(wire)
            s.member.handleWelcome(wire)
        }

        let sent = creatorMessaging.send(group, plaintext: V2Suite.utf8("now it works"))
        XCTAssertTrue(sent.ok)
        let memberMessaging = V2GroupMessaging(identity: s.memberIdentity, group: s.member, e2: V2DataProcessor())
        let received = memberMessaging.receive(sent.wire!)
        XCTAssertTrue(received.ok)
        XCTAssertEqual(received.kind, "installed")
    }

    func testADeviceNotInTheResolvedGenerationsRosterIsRefusedEvenWithALeakedMaster() {
        let s = makeSetup(mode: .auto)
        let state = s.creator.stateStore.current(group)!
        let leakedMaster = s.creator.keyStore.get(group, state.stateHash)!.master!
        let strangerIdentity = makeIdentity("900")

        let strangerOutcome = V2DataProcessor().send(V2DataProcessor.SendParams(
            chatId: group, genesisOrBinding: state.genesisId, epoch: String(state.epoch), saltStateOrBindingHash: Base64Url.decode(state.stateHash)!, master: leakedMaster,
            senderIdentityPk: strangerIdentity.publicKey, senderIdentitySk: strangerIdentity.secretKey, permitHash: nil, plaintext: V2Suite.utf8("forged"), retryMsgId: nil
        ))!

        let memberMessaging = V2GroupMessaging(identity: makeIdentity("irrelevant"), group: s.member, e2: V2DataProcessor())
        let received = memberMessaging.receive(strangerOutcome.wire)
        XCTAssertFalse(received.ok)
        XCTAssertEqual(received.reason, "sender_not_in_roster")
    }

    func testRetryingASendReproducesTheIdenticalWire() {
        let s = makeSetup(mode: .auto)
        let messaging = V2GroupMessaging(identity: s.creatorIdentity, group: s.creator, e2: V2DataProcessor())
        let first = messaging.send(group, plaintext: V2Suite.utf8("retry me"))
        let retry = messaging.send(group, plaintext: V2Suite.utf8("retry me"), retryMsgId: first.msgId)
        XCTAssertEqual(first.wire, retry.wire)
        XCTAssertEqual(first.msgId, retry.msgId)
    }
}
