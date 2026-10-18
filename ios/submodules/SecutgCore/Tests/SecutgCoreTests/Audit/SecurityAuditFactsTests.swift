import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.46: reducing a chat's raw facts (Web reference `audit/snapshot.test.ts`), the ignore list, the stored
/// preferences, and the reader against a real keyring.
final class SecurityAuditFactsTests: XCTestCase {
    private func facts(_ chatId: String = "800", kind: SecurityAudit.ChatKind = .privateChat, hasKey: Bool = true,
                       v1: SecurityAuditFacts.V1Pairing? = nil, binding: SecurityAuditFacts.V2Binding? = nil,
                       transaction: SecurityAuditFacts.V2Transaction? = nil, invite: SecurityAuditFacts.V2Invite? = nil,
                       keyRequired: SecurityAuditFacts.KeyRequiredFacts? = nil) -> SecurityAuditFacts.ChatFacts {
        return SecurityAuditFacts.ChatFacts(chatId: chatId, kind: kind, hasKey: hasKey, v1Pairing: v1, v2Binding: binding,
                                            v2Transaction: transaction, v2Invite: invite, groupKeyCreatedMs: 5, keyRequired: keyRequired)
    }

    private func binding(verified: Bool = false, suspended: Bool = false, mismatch: Bool = false, override: Bool = false, cloned: Bool = false) -> SecurityAuditFacts.V2Binding {
        return SecurityAuditFacts.V2Binding(verified: verified, suspended: suspended, mismatch: mismatch, mismatchOverride: override, cloned: cloned)
    }

    func testV2BindingOutranksV1() {
        let chat = SecurityAuditFacts.assemble(facts(v1: .init(state: "invited", verified: false), binding: binding(verified: true)))
        XCTAssertEqual(chat.pairing, .paired)
        XCTAssertTrue(chat.verified)
    }

    func testV2BindingStates() {
        XCTAssertEqual(SecurityAuditFacts.assemble(facts(binding: binding(suspended: true))).pairing, .suspended)
        XCTAssertEqual(SecurityAuditFacts.assemble(facts(binding: binding(mismatch: true))).pairing, .mismatch)
        XCTAssertEqual(SecurityAuditFacts.assemble(facts(binding: binding(mismatch: true, override: true))).pairing, .mismatchOverride)
        XCTAssertTrue(SecurityAuditFacts.assemble(facts(binding: binding(cloned: true))).cloned)
    }

    func testTransactionThenV1() {
        XCTAssertEqual(SecurityAuditFacts.assemble(facts(v1: .init(state: "paired", verified: true), transaction: .conflict)).pairing, .conflict)
        XCTAssertEqual(SecurityAuditFacts.assemble(facts(v1: .init(state: "invited", verified: false))).pairing, .waiting)
        XCTAssertEqual(SecurityAuditFacts.assemble(facts(v1: .init(state: "other_device", verified: false))).pairing, .conflict)
        XCTAssertEqual(SecurityAuditFacts.assemble(facts()).pairing, .none)
    }

    func testInvites() {
        // no binding: any live invite is waiting for an answer
        let plain = SecurityAuditFacts.assemble(facts(invite: .init(isNewerThanBinding: true, isUnknownIdentity: false)))
        XCTAssertTrue(plain.inviteReceived)
        XCTAssertFalse(plain.keyChangedInvite)
        // an invite older than the binding is history, not an offer
        let stale = SecurityAuditFacts.assemble(facts(binding: binding(), invite: .init(isNewerThanBinding: false, isUnknownIdentity: true)))
        XCTAssertFalse(stale.inviteReceived)
        XCTAssertFalse(stale.keyChangedInvite)
        // 3.43: a newer invite from an identity the binding has never seen
        let changed = SecurityAuditFacts.assemble(facts(binding: binding(), invite: .init(isNewerThanBinding: true, isUnknownIdentity: true)))
        XCTAssertTrue(changed.keyChangedInvite)
        XCTAssertFalse(changed.inviteReceived)
        XCTAssertTrue(SecurityAuditFacts.assemble(facts(v1: .init(state: "key_changed", verified: false))).keyChangedInvite)
    }

    func testKeyRequiredIsNullForANeverEncryptedChat() {
        XCTAssertNil(SecurityAuditFacts.assemble(facts(hasKey: false, keyRequired: .init(isOn: false, offHadKey: false))).keyRequired)
        XCTAssertEqual(SecurityAuditFacts.assemble(facts(hasKey: false, keyRequired: .init(isOn: false, offHadKey: true))).keyRequired, false)
        XCTAssertEqual(SecurityAuditFacts.assemble(facts(hasKey: false, keyRequired: .init(isOn: true, offHadKey: false))).keyRequired, true)
        XCTAssertNil(SecurityAuditFacts.assemble(facts()).keyRequired)
    }

    func testGroupKeyTimeOnlyForGroups() {
        XCTAssertNil(SecurityAuditFacts.assemble(facts()).groupKeyCreatedMs)
        XCTAssertEqual(SecurityAuditFacts.assemble(facts("-5", kind: .group)).groupKeyCreatedMs, 5)
    }

    func testSnapshotCarriesTheAppHalf() {
        let snapshot = SecurityAuditFacts.snapshot(
            runtime: SecurityAuditFacts.RuntimePart(chats: [facts()], localCiphertext: false, wipePhraseSet: true, wipeListens: false, lastKeyChangeMs: 9),
            app: SecurityAuditFacts.AppPart(groupKeyMaxAgeDays: 30, apiCredentialSource: .bundled, netGateEnabled: true,
                                            lastBackupMs: 3, ownVersion: "1.0", newestPeerVersion: nil, assistant: nil))
        XCTAssertEqual(snapshot.chats.count, 1)
        XCTAssertEqual(snapshot.settings.groupKeyMaxAgeDays, 30)
        XCTAssertEqual(snapshot.settings.apiCredentialSource, .bundled)
        XCTAssertFalse(snapshot.settings.localCiphertext)
        XCTAssertEqual(snapshot.lastBackupMs, 3)
        XCTAssertEqual(snapshot.lastKeyChangeMs, 9)
        XCTAssertNil(snapshot.assistant)
    }

    func testIgnoringDropsExpiredEntries() {
        let now: Int64 = 1_790_000_000_000
        let old = now - SecurityAudit.ignoreDurationMs
        let next = SecurityAudit.ignoring(["old": old, "recent": now - 1, "future": now + 1, "max": Int64.max, "min": Int64.min],
                                          id: "new", nowMs: now)
        XCTAssertEqual(next, ["recent": now - 1, "new": now])
        // a time in the future, or an extreme stored value, hides nothing — and does not trap
        XCTAssertFalse(SecurityAudit.isIgnoreActive(now + 1, nowMs: now))
        XCTAssertFalse(SecurityAudit.isIgnoreActive(Int64.min, nowMs: now))
        XCTAssertFalse(SecurityAudit.isIgnoreActive(Int64.max, nowMs: now))
        XCTAssertTrue(SecurityAudit.isIgnoreActive(now, nowMs: now))
        XCTAssertFalse(SecurityAudit.isIgnoreActive(now - SecurityAudit.ignoreDurationMs, nowMs: now))
    }

    func testPrefsCodec() {
        XCTAssertEqual(SecurityAuditPrefs.parseIgnored(SecurityAuditPrefs.serializeIgnored(["c8:-:bundled": 12])), ["c8:-:bundled": 12])
        XCTAssertEqual(SecurityAuditPrefs.parseIgnored("{\"a\": true, \"b\": \"x\", \"c\": 1.5, \"d\": 7}"), ["d": 7])
        XCTAssertEqual(SecurityAuditPrefs.parseIgnored("[1]"), [:])
        XCTAssertEqual(SecurityAuditPrefs.parseIgnored(nil), [:])
        XCTAssertEqual(SecurityAuditPrefs.parseGroupKeyDays("30"), 30)
        XCTAssertEqual(SecurityAuditPrefs.parseGroupKeyDays("0"), 90)
        XCTAssertEqual(SecurityAuditPrefs.parseGroupKeyDays("x"), 90)
        XCTAssertNil(SecurityAuditPrefs.serializeGroupKeyDays(0))
        XCTAssertEqual(SecurityAuditPrefs.parseLastBackupMs("123"), 123)
        XCTAssertNil(SecurityAuditPrefs.parseLastBackupMs("-1"))
        XCTAssertEqual(Set(SecurityAuditPrefs.allKeys(accountKey: "7")).count, 3)
        XCTAssertFalse(SecurityAuditPrefs.allKeys(accountKey: "7").contains(where: { $0.hasSuffix(".70") }))
    }

    /// PLAN.md 3.46.2 checks 12/13: nil is silent (read failed / not attempted), never a finding.
    func testTwoStepAndOtherSessionsChecks() {
        let base = SecurityAuditFacts.snapshot(
            runtime: .empty,
            app: SecurityAuditFacts.AppPart(groupKeyMaxAgeDays: 90, apiCredentialSource: .user, netGateEnabled: true,
                                            lastBackupMs: nil, ownVersion: nil, newestPeerVersion: nil, assistant: nil))
        XCTAssertFalse(SecurityAudit.run(base, nowMs: 0).contains { $0.check == 12 })
        XCTAssertFalse(SecurityAudit.run(base, nowMs: 0).contains { $0.check == 13 })

        func withAccount(_ account: SecurityAudit.Account) -> SecurityAudit.Snapshot {
            return SecurityAudit.Snapshot(chats: base.chats, settings: base.settings, lastBackupMs: base.lastBackupMs,
                                          lastKeyChangeMs: base.lastKeyChangeMs, ownVersion: base.ownVersion,
                                          newestPeerSeen: base.newestPeerSeen, assistant: base.assistant, account: account)
        }

        let off = SecurityAudit.run(withAccount(.init(twoStepPassword: false, otherSessions: nil)), nowMs: 0)
        XCTAssertEqual(off.first { $0.check == 12 }?.level, .risk)
        XCTAssertEqual(off.first { $0.check == 12 }?.action, .openTwoStep)

        let on = SecurityAudit.run(withAccount(.init(twoStepPassword: true, otherSessions: nil)), nowMs: 0)
        XCTAssertEqual(on.first { $0.check == 12 }?.level, .ok)

        let none = SecurityAudit.run(withAccount(.init(twoStepPassword: nil, otherSessions: 0)), nowMs: 0)
        XCTAssertEqual(none.first { $0.check == 13 }?.level, .ok)
        XCTAssertEqual(none.first { $0.check == 13 }?.action, .openSessions)

        let others = SecurityAudit.run(withAccount(.init(twoStepPassword: nil, otherSessions: 3)), nowMs: 0)
        XCTAssertEqual(others.first { $0.check == 13 }?.level, .warn)
        XCTAssertEqual(others.first { $0.check == 13 }?.params["count"], .int(3))
    }

    /// PLAN.md 3.46 补充（2026-10-04）: the page's 10s timeout (or a failed read) reports `.unavailable` for
    /// checks 12/13 instead of staying silent, and `summarize` does not count `.unavailable` as risk/warn/ok.
    func testTwoStepAndOtherSessionsUnavailable() {
        let base = SecurityAuditFacts.snapshot(
            runtime: .empty,
            app: SecurityAuditFacts.AppPart(groupKeyMaxAgeDays: 90, apiCredentialSource: .user, netGateEnabled: true,
                                            lastBackupMs: nil, ownVersion: nil, newestPeerVersion: nil, assistant: nil))

        func withAccount(_ account: SecurityAudit.Account) -> SecurityAudit.Snapshot {
            return SecurityAudit.Snapshot(chats: base.chats, settings: base.settings, lastBackupMs: base.lastBackupMs,
                                          lastKeyChangeMs: base.lastKeyChangeMs, ownVersion: base.ownVersion,
                                          newestPeerSeen: base.newestPeerSeen, assistant: base.assistant, account: account)
        }

        let bothTimedOut = SecurityAudit.run(
            withAccount(.init(twoStepPassword: nil, otherSessions: nil, twoStepUnavailable: true, otherSessionsUnavailable: true)),
            nowMs: 0)
        XCTAssertEqual(bothTimedOut.first { $0.check == 12 }?.level, .unavailable)
        XCTAssertEqual(bothTimedOut.first { $0.check == 12 }?.action, .openTwoStep)
        XCTAssertEqual(bothTimedOut.first { $0.check == 13 }?.level, .unavailable)
        XCTAssertEqual(bothTimedOut.first { $0.check == 13 }?.action, .openSessions)

        // `.unavailable` findings are not risk/warn/ok, so `summarize` does not count check 12/13 at all here.
        let summary = SecurityAudit.summarize(bothTimedOut)
        XCTAssertEqual(summary.risk + summary.warn + summary.ok, bothTimedOut.filter { $0.check != 12 && $0.check != 13 }.count)

        // The unavailable flag wins over a stale value — a timed-out read never also reports an answer.
        let oneUnavailable = SecurityAudit.run(
            withAccount(.init(twoStepPassword: true, otherSessions: 0, twoStepUnavailable: true, otherSessionsUnavailable: false)),
            nowMs: 0)
        XCTAssertEqual(oneUnavailable.first { $0.check == 12 }?.level, .unavailable)
        XCTAssertEqual(oneUnavailable.first { $0.check == 13 }?.level, .ok)
    }

    func testVersionCompareFollowsParseInt() {
        XCTAssertEqual(SecurityAudit.compareVersions("1.2.3", "1.2.3").sign, 0)
        XCTAssertEqual(SecurityAudit.compareVersions("1.2", "1.2.1").sign, -1)
        XCTAssertEqual(SecurityAudit.compareVersions("2.0b", "2.0").sign, 0)
        XCTAssertEqual(SecurityAudit.compareVersions("1.9", "2.0").major, -1)
    }

    func testCodeUnitOrder() {
        XCTAssertLessThan(SecurityAudit.compareCodeUnits("", "-1"), 0)
        XCTAssertLessThan(SecurityAudit.compareCodeUnits("-1", "1"), 0)
        XCTAssertLessThan(SecurityAudit.compareCodeUnits("10", "9"), 0)
        XCTAssertEqual(SecurityAudit.compareCodeUnits("ab", "ab"), 0)
    }

    func testKindOf() {
        XCTAssertEqual(SecurityAuditReader.kindOf("800", ownUserId: "1"), .privateChat)
        XCTAssertEqual(SecurityAuditReader.kindOf("1", ownUserId: "1"), .saved)
        XCTAssertEqual(SecurityAuditReader.kindOf("-5", ownUserId: "1"), .group)
        XCTAssertEqual(SecurityAuditReader.kindOf("-1000000000005", ownUserId: "1"), .group)
        XCTAssertNil(SecurityAuditReader.kindOf("x", ownUserId: "1"))
    }

    /// The reader against a real keyring: a group key and a private key, no v2 runtime.
    func testReaderOnARealKeyring() throws {
        var now: Int64 = 1_790_000_000_000
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { now }, epochDays: 1, epochTolerance: 1)
        try ring.setChatMaster(chatId: "-5", masterId: try ring.addMaster([UInt8](repeating: 1, count: 32)), label: nil)
        now += 1000
        try ring.setChatMaster(chatId: "800", masterId: try ring.addMaster([UInt8](repeating: 2, count: 32)), label: nil)
        let part = SecurityAuditReader.runtimePart(ring: ring, v2: nil, ownUserId: "1")
        XCTAssertEqual(part.chats.map { $0.chatId }, ["-5", "800"])
        XCTAssertEqual(part.chats.first?.kind, .group)
        XCTAssertEqual(part.chats.first?.groupKeyCreatedMs, 1_790_000_000_000)
        XCTAssertTrue(part.chats.allSatisfy { $0.hasKey })
        XCTAssertEqual(part.lastKeyChangeMs, 1_790_000_001_000)
        XCTAssertNil(part.chats.last?.groupKeyCreatedMs)
        // nothing in the facts can carry a key: every field is a state, a time or a count
        let snapshot = SecurityAuditFacts.snapshot(runtime: part, app: SecurityAuditFacts.AppPart(
            groupKeyMaxAgeDays: 90, apiCredentialSource: .user, netGateEnabled: true, lastBackupMs: nil,
            ownVersion: nil, newestPeerVersion: nil, assistant: nil))
        let findings = SecurityAudit.run(snapshot, nowMs: now)
        XCTAssertTrue(findings.contains { $0.id == "c7:-:never" && $0.level == .risk })
        XCTAssertTrue(findings.contains { $0.id == "c3:-5:fresh" })
    }

    /// The check-up is read-only (3.46 纯本地，只读): a lagging forward-secrecy ratchet is not walked, nothing persists.
    func testReaderNeverWalksARatchetAndRatchetStepsAreNotKeyChanges() throws {
        let day: Int64 = 86_400_000
        var now: Int64 = 1_790_000_000_000
        let storage = MemoryKeyRingStorage()
        let ring = KeyRing(storage: storage, clock: { now }, epochDays: 1, epochTolerance: 1)
        try ring.setChatMaster(chatId: "-5", masterId: try ring.addMaster([UInt8](repeating: 1, count: 32)), label: nil)
        let oldLabel = KeyDerivation.toEpochLabel(nowMs: now - 5 * day, epochDays: 1)
        now += 1000
        let ratchetMaster = try ring.addMaster([UInt8](repeating: 2, count: 32))
        try ring.setChatMaster(chatId: "800", masterId: ratchetMaster, label: oldLabel)
        try ring.setChatRatchet(chatId: "800", label: oldLabel, masterId: ratchetMaster)
        let before = storage.saved

        let part = SecurityAuditReader.runtimePart(ring: ring, v2: nil, ownUserId: "1")

        XCTAssertEqual(storage.saved, before, "the reader persisted the keyring")
        XCTAssertEqual(ring.chatRatchet("800")?.label, oldLabel)
        XCTAssertEqual(ring.chatMasterId("800"), ratchetMaster)
        XCTAssertTrue(part.chats.first { $0.chatId == "800" }?.hasKey ?? false)
        // check 7: only the group's master counts; the ratchet chat's (newer) master is a chain step, not a new key
        XCTAssertEqual(part.lastKeyChangeMs, 1_790_000_000_000)
    }

    /// A device whose only encrypted chat is a v2 group still gets check 3 and check 7 (as Web and Android).
    func testReaderSeesAV2OnlyGroup() throws {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        let stored = KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
        let identity = try XCTUnwrap(V2IdentityBridge.identity(userId: "1", from: stored))
        let runtime = V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: V2MemoryStorage()))
        XCTAssertNotNil(runtime.group.genesis("-5", mode: .auto))
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { 1_790_000_000_000 }, epochDays: 1, epochTolerance: 1)

        let part = SecurityAuditReader.runtimePart(ring: ring, v2: runtime, ownUserId: "1")
        XCTAssertEqual(part.chats.map { $0.chatId }, ["-5"])
        XCTAssertEqual(part.chats.first?.kind, .group)
        XCTAssertTrue(part.chats.first?.hasKey ?? false)
        let snapshot = SecurityAuditFacts.snapshot(runtime: part, app: SecurityAuditFacts.AppPart(
            groupKeyMaxAgeDays: 90, apiCredentialSource: .user, netGateEnabled: true, lastBackupMs: nil,
            ownVersion: nil, newestPeerVersion: nil, assistant: nil))
        XCTAssertTrue(SecurityAudit.run(snapshot, nowMs: 1_790_000_000_000).contains { $0.id == "c7:-:never" })
    }
}
