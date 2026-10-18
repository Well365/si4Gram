import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.47: the catch-up pass's pure rules — which messages, which chats, in what order, how much per pass.
final class CatchUpTests: XCTestCase {
    private let e1 = "E1:k1.20260101:AAAAAAAA:BBBBBBBBBBBB"
    private let e2 = "E2:eyJhIjoxfQ"
    private let g2 = "G2:-100:1700000000:AAAA:42"
    private let gp1 = "GP1:-100:1700000000:AAAA:42"
    private let u1 = "U1:42:1700000000:c2lnbmF0dXJl"

    private func p2Invite() -> String {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        let stored = KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
        let identity = V2IdentityBridge.identity(userId: "111", from: stored)!
        let b64 = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("INVITE")))
        let params = V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: V2Envelope.randomId(), chatId: "222", actorUser: identity.userId,
            actorIdentityPk: identity.publicKey, actorIdentitySk: identity.secretKey, parentBinding: nil,
            createdMs: "1700000000000", expiresMs: "1700000600000")
        return V2Messages.buildInvite(params, V2Messages.InviteBody(intent: "new", identityPk: b64, ephemeralPk: b64,
                                                                    encapsulationPk: b64, targetUser: "222", challenge: b64))!
    }

    // MARK: candidates

    func testEveryWireFamilyTheHookHandlesIsACandidate() {
        for wire in [e1, e2, g2, gp1, u1, p2Invite()] {
            XCTAssertTrue(CatchUp.isSecutgWire(wire), wire)
            XCTAssertTrue(CatchUp.isCandidate(text: wire, hasSecutgMeta: false), wire)
        }
    }

    func testAMessageTheHookAlreadyTaggedIsNeverACandidate() {
        // P2 lines stored by the hook carry `.control`, decrypted / sealed ones `.decrypted` / `.sealed`
        for wire in [e1, e2, g2, gp1, u1, p2Invite()] {
            XCTAssertFalse(CatchUp.isCandidate(text: wire, hasSecutgMeta: true), wire)
        }
    }

    func testWordsThatMerelyStartLikeAWireAreNotCandidates() {
        for text in ["", "hello", "E1: hi there", "P2: let's meet", "E2: not base64!", "G2:abc", "G1:-100:AAAA:BBBB", "R1:rotate"] {
            XCTAssertFalse(CatchUp.isCandidate(text: text, hasSecutgMeta: false), text)
        }
    }

    // MARK: rows outside the pass (PLAN.md 3.17 sweep, rendering)

    func testContentWiresAreE1AndE2Only() {
        XCTAssertTrue(CatchUp.isContentWire(e1))
        XCTAssertTrue(CatchUp.isContentWire(e2))
        for text in [g2, gp1, u1, p2Invite(), "", "hello", "E1: hi there", "E2: not base64!"] {
            XCTAssertFalse(CatchUp.isContentWire(text), text)
        }
    }

    func testRedecryptSweepAlsoOpensUnmarkedContentWires() {
        // 2026-10-01 真机: the extension stored these with no meta; the old sweep selected `.undecryptable` only
        XCTAssertTrue(CatchUp.isRedecryptCandidate(text: e1, stored: .unmarked))
        XCTAssertTrue(CatchUp.isRedecryptCandidate(text: e2, stored: .unmarked))
        // the old rule is unchanged
        XCTAssertTrue(CatchUp.isRedecryptCandidate(text: e1, stored: .undecryptable))
        XCTAssertTrue(CatchUp.isRedecryptCandidate(text: e2, stored: .undecryptable))
        XCTAssertFalse(CatchUp.isRedecryptCandidate(text: "", stored: .undecryptable))
    }

    func testRedecryptSweepNeverTouchesSettledRowsPlainTextOrControlLines() {
        // a decrypted message whose words look like a wire carries `.decrypted`; re-reading it would destroy it
        for wire in [e1, e2, g2, u1] {
            XCTAssertFalse(CatchUp.isRedecryptCandidate(text: wire, stored: .other), wire)
        }
        // unmarked control lines are the catch-up pass's (its own entry, idempotent), not the key sweep's
        for text in [g2, gp1, u1, p2Invite(), "hello", "E1: hi there", "E2: not base64!", ""] {
            XCTAssertFalse(CatchUp.isRedecryptCandidate(text: text, stored: .unmarked), text)
        }
    }

    func testAnUnmarkedWireRendersTheLoadingNoticeNeverItsText() {
        for wire in [e1, e2, g2, gp1, u1, p2Invite()] {
            XCTAssertEqual(CatchUp.unmarkedWireNotice(text: wire, hasSecutgMeta: false), "not_ready", wire)
            XCTAssertNil(CatchUp.unmarkedWireNotice(text: wire, hasSecutgMeta: true), wire)
        }
        for text in ["", "hello", "E1: hi there", "G1:-100:AAAA:BBBB"] {
            XCTAssertNil(CatchUp.unmarkedWireNotice(text: text, hasSecutgMeta: false), text)
        }
    }

    /// The real-device sequence end to end on the pure rules: rows stored by the extension with no meta, a first
    /// enable that used to bury them, then a key import whose sweep must select them.
    func testRowsStoredWithoutMetaAreReachedByLookBackAndBySweep() {
        let chat = "222"
        // 600 messages, the extension stored wires at 590, 595 and 10 (the last one beyond the look-back)
        let ids: [Int32] = Array((1...600).reversed())
        let texts: [Int32: String] = [590: e2, 595: e1, 10: e2]
        let marks = CatchUpWatermarks.firstEnabled([CatchUp.ChatTop(chatId: chat, topMessageId: 600)])
        let due = CatchUp.dueChats([CatchUp.ChatTop(chatId: chat, topMessageId: 600)], marks: marks)
        XCTAssertEqual(due.count, 1)
        // the runtime reads at most `scanWindow` messages newest first
        let window = ids.prefix(due[0].scanWindow).map { CatchUp.Scanned(id: $0, isCandidate: CatchUp.isCandidate(text: texts[$0] ?? "hi", hasSecutgMeta: false)) }
        let slice = CatchUp.slice(scanned: window, floor: due[0].floor, reachedFloor: true)
        XCTAssertEqual(slice.process, [590, 595])
        XCTAssertEqual(slice.advanceTo, 600)
        XCTAssertFalse(marks.advancing(chat, to: 600).isPendingLookback(chat))
        // message 10 stays unmarked under the watermark; the sweep after a key import still selects it
        XCTAssertTrue(CatchUp.isRedecryptCandidate(text: texts[10]!, stored: .unmarked))
    }

    // MARK: chats

    func testDueChatsAreThoseAboveTheirWatermarkNewestFirst() {
        let marks = CatchUpWatermarks(marks: ["1": 10, "2": 50, "3": 7])
        let due = CatchUp.dueChats([
            CatchUp.ChatTop(chatId: "1", topMessageId: 10), // at its mark: nothing new
            CatchUp.ChatTop(chatId: "2", topMessageId: 60),
            CatchUp.ChatTop(chatId: "3", topMessageId: 90),
            CatchUp.ChatTop(chatId: "-5", topMessageId: 3), // never seen: from 0
        ], marks: marks)
        XCTAssertEqual(due, [
            CatchUp.DueChat(chatId: "3", topMessageId: 90, floor: 7),
            CatchUp.DueChat(chatId: "2", topMessageId: 60, floor: 50),
            CatchUp.DueChat(chatId: "-5", topMessageId: 3, floor: 0),
        ])
    }

    func testDueChatsTieBreakOnChatIdAndIgnoreDuplicates() {
        let due = CatchUp.dueChats([
            CatchUp.ChatTop(chatId: "9", topMessageId: 5),
            CatchUp.ChatTop(chatId: "10", topMessageId: 5),
            CatchUp.ChatTop(chatId: "9", topMessageId: 99),
        ], marks: CatchUpWatermarks())
        XCTAssertEqual(due.map { $0.chatId }, ["10", "9"])
        XCTAssertEqual(due.last?.topMessageId, 5)
    }

    // MARK: slicing

    private func scanned(_ ids: [Int32], candidates: Set<Int32>) -> [CatchUp.Scanned] {
        return ids.map { CatchUp.Scanned(id: $0, isCandidate: candidates.contains($0)) }
    }

    func testSliceProcessesCandidatesAscendingAndAdvancesToTheTop() {
        // newest-first, as Postbox scans; 100 is at the watermark and must be ignored
        let slice = CatchUp.slice(scanned: scanned([105, 104, 103, 102, 101, 100], candidates: [104, 102, 100]), floor: 100, reachedFloor: true)
        XCTAssertEqual(slice, CatchUp.Slice(process: [102, 104], advanceTo: 105, remaining: 0, truncated: false))
    }

    func testSliceWithNothingAboveTheFloorLeavesTheWatermark() {
        XCTAssertEqual(CatchUp.slice(scanned: scanned([5, 4], candidates: [5]), floor: 5, reachedFloor: true),
                       CatchUp.Slice(process: [], advanceTo: nil, remaining: 0, truncated: false))
    }

    func testSliceWithoutCandidatesStillAdvances() {
        XCTAssertEqual(CatchUp.slice(scanned: scanned([8, 7, 6], candidates: []), floor: 0, reachedFloor: true),
                       CatchUp.Slice(process: [], advanceTo: 8, remaining: 0, truncated: false))
    }

    func testSliceCapStopsAtTheLastProcessedCandidate() {
        let ids: [Int32] = Array((1...20).reversed())
        let slice = CatchUp.slice(scanned: scanned(ids, candidates: [3, 6, 9, 12, 15, 18]), floor: 0, reachedFloor: true, limit: 4)
        XCTAssertEqual(slice.process, [3, 6, 9, 12])
        XCTAssertEqual(slice.advanceTo, 12) // never past 15, which was not processed
        XCTAssertEqual(slice.remaining, 2)
        // the next pass starts right there and finishes
        let next = CatchUp.slice(scanned: scanned(ids, candidates: [3, 6, 9, 12, 15, 18]), floor: 12, reachedFloor: true, limit: 4)
        XCTAssertEqual(next, CatchUp.Slice(process: [15, 18], advanceTo: 20, remaining: 0, truncated: false))
    }

    func testDefaultCapIsFiveHundred() {
        let ids: [Int32] = Array(1...600)
        let slice = CatchUp.slice(scanned: scanned(ids, candidates: Set(ids)), floor: 0, reachedFloor: true)
        XCTAssertEqual(slice.process.count, 500)
        XCTAssertEqual(slice.process.first, 1)
        XCTAssertEqual(slice.advanceTo, 500)
        XCTAssertEqual(slice.remaining, 100)
    }

    func testSliceDeduplicatesAndReportsATruncatedScan() {
        let slice = CatchUp.slice(scanned: [CatchUp.Scanned(id: 9, isCandidate: false), CatchUp.Scanned(id: 9, isCandidate: true),
                                            CatchUp.Scanned(id: 8, isCandidate: false)],
                                  floor: 2, reachedFloor: false)
        XCTAssertEqual(slice, CatchUp.Slice(process: [9], advanceTo: 9, remaining: 0, truncated: true))
    }

    // MARK: budget

    func testBudget() {
        let budget = CatchUp.Budget(startedAtMs: 1_000)
        XCTAssertEqual(budget.limitMs, 2_000)
        XCTAssertFalse(budget.isExhausted(nowMs: 2_999))
        XCTAssertTrue(budget.isExhausted(nowMs: 3_000))
        XCTAssertFalse(budget.isExhausted(nowMs: 500)) // clock went backwards: no time spent
    }
}
