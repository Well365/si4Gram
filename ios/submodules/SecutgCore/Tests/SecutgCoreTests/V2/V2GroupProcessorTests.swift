import XCTest
@testable import SecutgCore

/// Ported from Android's `GroupProcessorTest.java` — TEST_MATRIX.md G-01 through G-39, a
/// representative subset covering genesis/join, admin rekey (including concurrent-commit tiebreak),
/// device revocation, offline re-issue, and mode switching.
final class V2GroupProcessorTests: XCTestCase {
    private let group = "g-4200"

    private func makeIdentity(_ userId: String) -> V2Identity {
        let ed = V2Suite.generateEd25519()
        let enc = V2Suite.generateX25519()
        return V2Identity(userId: userId, publicKey: ed.publicKey, secretKey: ed.secretKey, encapsulationPk: enc.publicKey, encapsulationSk: enc.secretKey)
    }

    private func deviceId(_ identity: V2Identity) -> String {
        return Base64Url.encode(V2Suite.sha256(identity.publicKey))
    }

    private final class Setup {
        let creatorIdentity: V2Identity
        let memberIdentity: V2Identity
        let creator: V2GroupProcessor
        var member: V2GroupProcessor!
        var genesisOutcome: V2GroupProcessor.GenesisOutcome!
        var coAdminProcs: [V2GroupProcessor] = []
        let group: String
        let deviceIdOf: (V2Identity) -> String

        init(mode: V2GroupState.Mode, coAdmins: [V2Identity] = [], group: String, makeIdentity: (String) -> V2Identity, deviceIdOf: @escaping (V2Identity) -> String) {
            self.group = group
            self.deviceIdOf = deviceIdOf
            creatorIdentity = makeIdentity("100")
            memberIdentity = makeIdentity("200")
            creator = V2GroupProcessor(identity: creatorIdentity)
            guard let genesisOutcome = creator.genesis(group, mode: mode, coAdmins: coAdmins) else {
                fatalError("setup")
            }
            self.genesisOutcome = genesisOutcome
            for id in coAdmins {
                let proc = V2GroupProcessor(identity: id)
                proc.handleGenesis(genesisOutcome.wire)
                coAdminProcs.append(proc)
            }
            member = V2GroupProcessor(identity: memberIdentity)
            member.handleGenesis(genesisOutcome.wire)
            guard let joinOutcome = creator.handleJoinRequest(member.joinRequest(group)!, master: genesisOutcome.master) as V2GroupProcessor.JoinOutcome?, joinOutcome.ok else {
                fatalError("setup")
            }
            guard let welcomeOutcome = member.handleWelcome(joinOutcome.welcomeWire!) as V2GroupProcessor.WelcomeOutcome?, welcomeOutcome.ok else {
                fatalError("setup")
            }
            for proc in coAdminProcs {
                proc.stateStore.addDevice(groupId: group, deviceId: deviceIdOf(memberIdentity), keys: V2GroupState.DeviceKeys(identityPk: Base64Url.encode(memberIdentity.publicKey), encapsulationPk: Base64Url.encode(memberIdentity.encapsulationPk)))
            }
        }
    }

    private func makeSetup(mode: V2GroupState.Mode, coAdmins: [V2Identity] = []) -> Setup {
        return Setup(mode: mode, coAdmins: coAdmins, group: group, makeIdentity: makeIdentity, deviceIdOf: deviceId)
    }

    // MARK: A. genesis and first join (G-01..G-05)

    func testG01GenesisInstallsEpochZeroWithTheCreatorAsSoleAdmin() {
        let creatorIdentity = makeIdentity("100")
        let creator = V2GroupProcessor(identity: creatorIdentity)
        let outcome = creator.genesis(group, mode: .auto)
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome!.master.count, 32)

        let state = creator.stateStore.current(group)
        XCTAssertNotNil(state)
        XCTAssertEqual(state!.epoch, 0)
        XCTAssertEqual(state!.mode, .auto)
        XCTAssertEqual(state!.adminAcl.count, 1)
        XCTAssertEqual(state!.adminAcl[0].deviceId, deviceId(creatorIdentity))
        XCTAssertEqual(state!.deviceRoster.count, 1)

        let parsed = V2GroupMessages.parseGenesis(outcome!.wire)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.body.mode, .auto)
        XCTAssertEqual(parsed!.envelope.chatId, group)

        XCTAssertNil(creator.genesis(group, mode: .auto))
    }

    func testG02AnAdminIssuesAnIndependentPermitAndKeyByDeviceNotUser() {
        let s = makeSetup(mode: .auto)
        let adminState = s.creator.stateStore.current(group)!
        XCTAssertTrue(adminState.deviceRoster.contains(deviceId(s.creatorIdentity)))
        XCTAssertTrue(adminState.deviceRoster.contains(deviceId(s.memberIdentity)))
        XCTAssertEqual(adminState.deviceKeys[deviceId(s.memberIdentity)]?.encapsulationPk, Base64Url.encode(s.memberIdentity.encapsulationPk))
        XCTAssertTrue(s.member.stateStore.current(group)!.deviceRoster.contains(deviceId(s.memberIdentity)))
    }

    func testG03ASecondDeviceOfTheSameAccountRegistersIndependentlyNeverOverwriting() {
        let creatorIdentity = makeIdentity("100")
        let memberIdentity1 = makeIdentity("200")
        let memberIdentity2 = makeIdentity("200") // same account, second device
        let creator = V2GroupProcessor(identity: creatorIdentity)
        let genesisOutcome = creator.genesis(group, mode: .auto)!

        let member1 = V2GroupProcessor(identity: memberIdentity1)
        member1.handleGenesis(genesisOutcome.wire)
        let join1 = creator.handleJoinRequest(member1.joinRequest(group)!, master: genesisOutcome.master)
        XCTAssertTrue(join1.ok)
        let originalKeys = creator.stateStore.current(group)!.deviceKeys[deviceId(memberIdentity1)]!

        let member2 = V2GroupProcessor(identity: memberIdentity2)
        member2.handleGenesis(genesisOutcome.wire)
        let join2 = creator.handleJoinRequest(member2.joinRequest(group)!, master: genesisOutcome.master)
        XCTAssertTrue(join2.ok)

        let finalState = creator.stateStore.current(group)!
        XCTAssertEqual(finalState.deviceRoster.count, 3)
        XCTAssertTrue(finalState.deviceRoster.contains(deviceId(memberIdentity1)))
        XCTAssertTrue(finalState.deviceRoster.contains(deviceId(memberIdentity2)))
        XCTAssertEqual(finalState.deviceKeys[deviceId(memberIdentity1)]?.identityPk, originalKeys.identityPk)

        let replay = creator.handleJoinRequest(member1.joinRequest(group)!, master: genesisOutcome.master)
        XCTAssertFalse(replay.ok)
        XCTAssertEqual(replay.reason, "already_registered")
    }

    func testG04FaceToFacePathUsesTheSameContentOnlyAShorterTtl() {
        let creatorIdentity = makeIdentity("100")
        let memberIdentity = makeIdentity("200")
        let creator = V2GroupProcessor(identity: creatorIdentity)
        let genesisOutcome = creator.genesis(group, mode: .manual)!

        let member = V2GroupProcessor(identity: memberIdentity)
        member.handleGenesis(genesisOutcome.wire)
        let joinWire = member.joinRequest(group, ttlMs: V2GroupProcessor.qrTtlMs)!
        let parsedJoin = V2GroupMessages.parseJoinRequest(joinWire)!
        let ttl = (Int64(parsedJoin.envelope.expiresMs) ?? 0) - (Int64(parsedJoin.envelope.createdMs) ?? 0)
        XCTAssertEqual(ttl, V2GroupProcessor.qrTtlMs)

        let joinOutcome = creator.handleJoinRequest(joinWire, master: genesisOutcome.master)
        XCTAssertTrue(joinOutcome.ok)
        let welcomeOutcome = member.handleWelcome(joinOutcome.welcomeWire!)
        XCTAssertTrue(welcomeOutcome.ok)
        XCTAssertEqual(welcomeOutcome.master, genesisOutcome.master)

        let lateClock = Box<Int64>(Int64(Date().timeIntervalSince1970 * 1000) + V2GroupProcessor.qrTtlMs + 1)
        let lateCreator = V2GroupProcessor(identity: creatorIdentity, now: { lateClock.value })
        lateCreator.stateStore.installGenesis(creator.stateStore.current(group)!)
        let lateMember = makeIdentity("300")
        let lateMemberProc = V2GroupProcessor(identity: lateMember)
        lateMemberProc.handleGenesis(genesisOutcome.wire)
        let staleJoinWire = lateMemberProc.joinRequest(group, ttlMs: V2GroupProcessor.qrTtlMs)!
        let stale = lateCreator.handleJoinRequest(staleJoinWire, master: genesisOutcome.master)
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(stale.reason, "expired")
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    func testG05ANewMemberCanReadSameEpochHistoryNoIsolationPromised() {
        let s = makeSetup(mode: .auto)
        XCTAssertEqual(s.creator.stateStore.current(group)!.epoch, 0)
        XCTAssertEqual(s.member.stateStore.current(group)!.epoch, 0)
    }

    func testSignatureFailuresForgedJoinRequestAndWelcomeToWrongDeviceAreRefused() {
        let creatorIdentity = makeIdentity("100")
        let memberIdentity = makeIdentity("200")
        let impostorIdentity = makeIdentity("200")
        let creator = V2GroupProcessor(identity: creatorIdentity)
        let genesisOutcome = creator.genesis(group, mode: .auto)!

        let member = V2GroupProcessor(identity: memberIdentity)
        member.handleGenesis(genesisOutcome.wire)
        let joinWire = member.joinRequest(group)!
        let flip: Character = joinWire.hasSuffix("A") ? "B" : "A"
        let forged = String(joinWire.dropLast(4)) + String(flip) + joinWire.suffix(3)
        let forgedOutcome = creator.handleJoinRequest(forged, master: genesisOutcome.master)
        XCTAssertFalse(forgedOutcome.ok)

        let joinOutcome = creator.handleJoinRequest(joinWire, master: genesisOutcome.master)
        XCTAssertTrue(joinOutcome.ok)
        let impostor = V2GroupProcessor(identity: impostorIdentity)
        impostor.handleGenesis(genesisOutcome.wire)
        let impostorOutcome = impostor.handleWelcome(joinOutcome.welcomeWire!)
        XCTAssertFalse(impostorOutcome.ok)
        XCTAssertEqual(impostorOutcome.reason, "not_for_me")
    }

    // MARK: B. admin rekey (G-06..G-13)

    func testG06G07RotateAndRebuildRotateEpochAndMasterForTheSameRosterIssuerInstallsLikeAnyone() {
        for reason in ["rotate", "rebuild"] {
            let s = makeSetup(mode: .auto)
            let before = s.creator.stateStore.current(group)!

            let commitOutcome = s.creator.commit(group, reason: reason)
            XCTAssertNotNil(commitOutcome)
            XCTAssertEqual(s.creator.stateStore.current(group)!.stateHash, before.stateHash) // unchanged until resolved

            let handled = s.creator.handleCommit(commitOutcome!.commitWire, transportDate: 1_000)
            XCTAssertTrue(handled.ok)
            XCTAssertEqual(handled.kind, "buffered")
            let issuerResolved = s.creator.resolveCommits(group)
            XCTAssertTrue(issuerResolved.ok)
            XCTAssertEqual(issuerResolved.state!.epoch, before.epoch + 1)
            XCTAssertEqual(issuerResolved.state!.deviceRoster, before.deviceRoster)
            XCTAssertEqual(issuerResolved.state!.mode, .auto)
            XCTAssertEqual(issuerResolved.master, commitOutcome!.master)
            XCTAssertNotEqual(issuerResolved.master, s.genesisOutcome.master)

            XCTAssertTrue(s.member.handleCommit(commitOutcome!.commitWire, transportDate: 1_000).ok)
            let memberResolved = s.member.resolveCommits(group)
            XCTAssertTrue(memberResolved.ok)
            XCTAssertEqual(memberResolved.master, commitOutcome!.master)
        }
    }

    func testG08G09G10TwoAdminsSubmitConcurrentlyTiebreakConvergesEveryoneOnOneWinner() {
        let admin2Identity = makeIdentity("101")
        let s = makeSetup(mode: .auto, coAdmins: [admin2Identity])
        let admin2 = s.coAdminProcs[0]

        let commitA = s.creator.commit(group, reason: "rotate")!
        let commitB = admin2.commit(group, reason: "rotate")!
        XCTAssertNotEqual(commitA.commitWire, commitB.commitWire)

        s.member.handleCommit(commitA.commitWire, transportDate: 5_000)
        s.member.handleCommit(commitB.commitWire, transportDate: 5_000)
        let memberResolved = s.member.resolveCommits(group)
        XCTAssertTrue(memberResolved.ok)
        XCTAssertEqual(memberResolved.staleWires!.count, 1) // exactly one loser

        s.creator.handleCommit(commitA.commitWire, transportDate: 5_000)
        s.creator.handleCommit(commitB.commitWire, transportDate: 5_000)
        let creatorResolved = s.creator.resolveCommits(group)
        admin2.handleCommit(commitA.commitWire, transportDate: 5_000)
        admin2.handleCommit(commitB.commitWire, transportDate: 5_000)
        let admin2Resolved = admin2.resolveCommits(group)
        XCTAssertTrue(creatorResolved.ok)
        XCTAssertTrue(admin2Resolved.ok)
        XCTAssertEqual(creatorResolved.state!.stateHash, memberResolved.state!.stateHash)
        XCTAssertEqual(admin2Resolved.state!.stateHash, memberResolved.state!.stateHash)

        let loserOutcome = memberResolved.staleWires![0] == commitA.commitWire ? commitA : commitB
        XCTAssertNotEqual(loserOutcome.master, memberResolved.master)
    }

    func testG09ALateCommitThatWouldHaveBeatenTheInstalledWinnerIsConflictNotSilentlyLost() {
        let admin2Identity = makeIdentity("101")
        let s = makeSetup(mode: .auto, coAdmins: [admin2Identity])
        let admin2 = s.coAdminProcs[0]

        let commitA = s.creator.commit(group, reason: "rotate")!
        let commitB = admin2.commit(group, reason: "rotate")!

        s.member.handleCommit(commitA.commitWire, transportDate: 10_000)
        let firstResolve = s.member.resolveCommits(group)
        XCTAssertTrue(firstResolve.ok)

        let late = s.member.handleCommit(commitB.commitWire, transportDate: 9_000)
        XCTAssertTrue(late.ok)
        XCTAssertEqual(late.kind, "conflict")

        let notEarlyEnough = s.member.handleCommit(commitB.commitWire, transportDate: 10_001)
        XCTAssertTrue(notEarlyEnough.ok)
        XCTAssertEqual(notEarlyEnough.kind, "stale_parent")
    }

    func testG12CommitIsAuthorizedAgainstTheParentStatesAdminAclNonAdminIsRefused() {
        let s = makeSetup(mode: .auto)
        XCTAssertNil(s.member.commit(group, reason: "rotate"))
        let state = s.creator.stateStore.current(group)!
        let strangerDeviceId = deviceId(makeIdentity("200"))
        XCTAssertFalse(state.adminAcl.contains { $0.deviceId == strangerDeviceId })
    }

    func testG13ADeviceThatNeverJoinedNeverAppearsInARekeysRoster() {
        let strangerIdentity = makeIdentity("900")
        let s = makeSetup(mode: .auto)
        let commitOutcome = s.creator.commit(group, reason: "rotate")!
        s.creator.handleCommit(commitOutcome.commitWire, transportDate: 1_000)
        let resolved = s.creator.resolveCommits(group)
        XCTAssertTrue(resolved.ok)
        XCTAssertFalse(resolved.state!.deviceRoster.contains(deviceId(strangerIdentity)))
        XCTAssertNil(resolved.state!.deviceKeys[deviceId(strangerIdentity)])
    }

    func testManualModeNoPlaintextMasterInCommitDeliveryViaPerDeviceWelcomeOnlyIssuerIncluded() {
        let s = makeSetup(mode: .manual)
        let commitOutcome = s.creator.commit(group, reason: "rotate")!
        s.creator.handleCommit(commitOutcome.commitWire, transportDate: 1_000)
        let issuerResolved = s.creator.resolveCommits(group)
        XCTAssertTrue(issuerResolved.ok)
        XCTAssertNil(issuerResolved.master)

        s.member.handleCommit(commitOutcome.commitWire, transportDate: 1_000)
        let memberResolved = s.member.resolveCommits(group)
        XCTAssertTrue(memberResolved.ok)
        XCTAssertNil(memberResolved.master)

        let welcomeWires = s.creator.issueRekeyWelcomes(groupId: group, master: commitOutcome.master)
        XCTAssertNotNil(welcomeWires)
        XCTAssertEqual(welcomeWires!.count, issuerResolved.state!.deviceRoster.count)

        var creatorInstalled = 0
        var memberInstalled = 0
        for wire in welcomeWires! {
            if s.creator.handleWelcome(wire).ok { creatorInstalled += 1 }
            if s.member.handleWelcome(wire).ok { memberInstalled += 1 }
        }
        XCTAssertEqual(creatorInstalled, 1)
        XCTAssertEqual(memberInstalled, 1)
    }

    // MARK: C. member/device revocation (G-18..G-24)

    func testG19ASecondDeviceOfAnExistingMemberBumpsEpochAndDoesNotInheritPreAddHistory() {
        let memberIdentity2 = makeIdentity("200") // same account, second device
        let s = makeSetup(mode: .auto)
        let beforeEpoch = s.creator.stateStore.current(group)!.epoch

        let addOutcome = s.creator.commitAddDevice(groupId: group, newDeviceId: deviceId(memberIdentity2), newDeviceIdentityPkBytes: memberIdentity2.publicKey, newDeviceEncapsulationPkBytes: memberIdentity2.encapsulationPk, asAdmin: false)
        XCTAssertNotNil(addOutcome)
        s.creator.handleCommit(addOutcome!.commitWire, transportDate: 1_000)
        let resolved = s.creator.resolveCommits(group)
        XCTAssertTrue(resolved.ok)
        XCTAssertEqual(resolved.state!.epoch, beforeEpoch + 1)
        XCTAssertTrue(resolved.state!.deviceRoster.contains(deviceId(memberIdentity2)))
        XCTAssertNotEqual(resolved.master, s.genesisOutcome.master)

        s.member.handleCommit(addOutcome!.commitWire, transportDate: 1_000)
        let memberResolved = s.member.resolveCommits(group)
        XCTAssertTrue(memberResolved.ok)
        XCTAssertEqual(memberResolved.master, resolved.master)
    }

    func testG21ASingleDeviceIsRevokedOtherDeviceAndRestOfRosterAreUntouched() {
        let memberIdentity2 = makeIdentity("200")
        let s = makeSetup(mode: .auto)
        let addOutcome = s.creator.commitAddDevice(groupId: group, newDeviceId: deviceId(memberIdentity2), newDeviceIdentityPkBytes: memberIdentity2.publicKey, newDeviceEncapsulationPkBytes: memberIdentity2.encapsulationPk, asAdmin: false)!
        s.creator.handleCommit(addOutcome.commitWire, transportDate: 1_000)
        s.creator.resolveCommits(group)
        s.member.handleCommit(addOutcome.commitWire, transportDate: 1_000)
        s.member.resolveCommits(group)
        XCTAssertEqual(s.creator.stateStore.current(group)!.deviceRoster.count, 3)

        let removeOutcome = s.creator.commitRemoveDevice(groupId: group, targetDeviceId: deviceId(memberIdentity2))
        XCTAssertNotNil(removeOutcome)
        s.creator.handleCommit(removeOutcome!.commitWire, transportDate: 2_000)
        let resolved = s.creator.resolveCommits(group)
        XCTAssertTrue(resolved.ok)

        XCTAssertEqual(resolved.state!.deviceRoster.count, 2)
        XCTAssertFalse(resolved.state!.deviceRoster.contains(deviceId(memberIdentity2)))
        XCTAssertTrue(resolved.state!.deviceRoster.contains(deviceId(s.creatorIdentity)))
        XCTAssertTrue(resolved.state!.deviceRoster.contains(deviceId(s.memberIdentity)))
        XCTAssertNotNil(resolved.state!.deviceKeys[deviceId(memberIdentity2)]) // grown, never shrunk
    }

    // MARK: D. offline catch-up (G-25..G-35)

    @discardableResult
    private func rekeyRound(_ creator: V2GroupProcessor, _ member: V2GroupProcessor, _ transportDate: Int64, _ deliverWelcome: Bool) -> V2GroupProcessor.CommitOutcome {
        let outcome = creator.commit(group, reason: "rotate")!
        creator.handleCommit(outcome.commitWire, transportDate: transportDate)
        XCTAssertTrue(creator.resolveCommits(group).ok)
        member.handleCommit(outcome.commitWire, transportDate: transportDate)
        XCTAssertTrue(member.resolveCommits(group).ok)

        let welcomes = creator.issueRekeyWelcomes(groupId: group, master: outcome.master)!
        for wire in welcomes { creator.handleWelcome(wire) }
        if deliverWelcome { for wire in welcomes { member.handleWelcome(wire) } }
        return outcome
    }

    func testG28AnAdminReissuesOneMissingGenerationsKeyInstallsAsHistoricalCurrentUntouched() {
        let s = makeSetup(mode: .manual)
        rekeyRound(s.creator, s.member, 1_000, false) // this generation's WELCOME never arrives for member...
        rekeyRound(s.creator, s.member, 2_000, true) // ...but the NEXT one does
        let missingBefore = s.member.keyStore.missing(group)
        XCTAssertEqual(missingBefore.count, 1)
        let missingStateHash = missingBefore[0].stateHash
        let currentBefore = s.member.stateStore.current(group)!.stateHash
        XCTAssertNotEqual(missingStateHash, currentBefore)

        let reissued = s.creator.reissueWelcome(groupId: group, targetDeviceId: deviceId(s.memberIdentity), targetStateHash: missingStateHash)
        XCTAssertNotNil(reissued)

        let outcome = s.member.handleWelcome(reissued!)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(s.member.keyStore.get(group, missingStateHash)?.status, .historical)
        XCTAssertEqual(s.member.stateStore.current(group)!.stateHash, currentBefore)

        let strangerId = deviceId(makeIdentity("900"))
        XCTAssertNil(s.creator.reissueWelcome(groupId: group, targetDeviceId: strangerId, targetStateHash: missingStateHash))
    }

    // MARK: E. mode switching (G-36..G-37)

    func testG36ManualToAutoSuspendsSendingOnEveryDeviceUntilItIndividuallyConfirms() {
        let s = makeSetup(mode: .manual)
        let outcome = s.creator.commitSwitchMode(group, newMode: .auto)
        XCTAssertNotNil(outcome)

        s.creator.handleCommit(outcome!.commitWire, transportDate: 1_000)
        let creatorResolved = s.creator.resolveCommits(group)
        XCTAssertTrue(creatorResolved.ok)
        XCTAssertEqual(creatorResolved.state!.mode, .auto)
        XCTAssertNotNil(creatorResolved.master)
        XCTAssertFalse(s.creator.canSend(group))

        s.member.handleCommit(outcome!.commitWire, transportDate: 1_000)
        XCTAssertTrue(s.member.resolveCommits(group).ok)
        XCTAssertFalse(s.member.canSend(group))

        s.creator.confirmModeSwitch(group)
        XCTAssertTrue(s.creator.canSend(group))
        XCTAssertFalse(s.member.canSend(group))

        s.member.confirmModeSwitch(group)
        XCTAssertTrue(s.member.canSend(group))
    }

    func testG37AutoToManualConfirmingAloneWithoutTheKeyStillNeverGrantsSending() {
        let s = makeSetup(mode: .auto)
        let outcome = s.creator.commitSwitchMode(group, newMode: .manual)
        XCTAssertNotNil(outcome)

        s.creator.handleCommit(outcome!.commitWire, transportDate: 1_000)
        XCTAssertTrue(s.creator.resolveCommits(group).ok)
        XCTAssertFalse(s.creator.canSend(group))

        s.member.handleCommit(outcome!.commitWire, transportDate: 1_000)
        XCTAssertTrue(s.member.resolveCommits(group).ok)

        s.member.confirmModeSwitch(group)
        XCTAssertFalse(s.member.canSend(group))

        let welcomes = s.creator.issueRekeyWelcomes(groupId: group, master: outcome!.master)!
        for wire in welcomes {
            s.creator.handleWelcome(wire)
            s.member.handleWelcome(wire)
        }
        XCTAssertFalse(s.creator.canSend(group))
        s.creator.confirmModeSwitch(group)
        XCTAssertTrue(s.creator.canSend(group))
        XCTAssertTrue(s.member.canSend(group))
    }

    func testG17TotalAdminKeyLossHasNoSilentTakeoverPathRecoveryNeedsAGenuinelyNewGroupId() {
        let s = makeSetup(mode: .auto)
        XCTAssertNil(s.creator.genesis(group, mode: .auto))
        let recoveryOutcome = s.creator.genesis("g-9999-recovery", mode: .auto)
        XCTAssertNotNil(recoveryOutcome)
        let original = s.creator.stateStore.current(group)!
        let recovered = s.creator.stateStore.current("g-9999-recovery")!
        XCTAssertNotEqual(original.genesisId, recovered.genesisId)
    }
}
