import XCTest
@testable import SecutgCore

/// PLAN.md 3.35 — the auto mode's whole distribution mechanism, after the `R1 welcome` road was abandoned.
/// `G2` carries the QR code's own payload, wrapped, into the group.
///
/// What these tests pin is mostly the ABSENCE of things: no signature to verify, no public key to have
/// registered first, no recipient intersection, no round trip. 3.35.1 lists the seven silent gates that road
/// had, and every one of them is a way for a member to end up with no key and nothing on screen. The only gate
/// left is the publisher check, and 3.35.4 requires it to be three-state so that it too can never be silent.
final class G2FormatTests: XCTestCase {
    let group = "-1001234567890"
    let admin = "7001"
    let at: Int64 = 1_789_300_000

    var autoPayload: String!
    var manualPayload: String!

    override func setUpWithError() throws {
        let master = [UInt8](repeating: 7, count: 32)
        let adminPk = try Rekey.generateIdentity().ed25519Pk
        autoPayload = KeyPayload.build(masterKey: master, adminPk: adminPk, mode: .auto)
        manualPayload = KeyPayload.build(masterKey: master, adminPk: adminPk, mode: .manual)
    }

    func testRoundTripsCarryingTheQrPayloadUnchanged() throws {
        let wire = try XCTUnwrap(G2.build(chatId: group, at: at, keyPayload: autoPayload, publisherId: admin))
        let parsed = try XCTUnwrap(G2.parse(wire))
        XCTAssertEqual(parsed.chatId, group)
        XCTAssertEqual(parsed.at, at)
        XCTAssertEqual(parsed.publisherId, admin)
        // The point of 3.35: the same self-contained payload the QR code carries, not a new key format.
        XCTAssertEqual(parsed.keyPayload, autoPayload)
    }

    func testIsAControlMessageSoItNeverRendersAsChatText() throws {
        let wire = try XCTUnwrap(G2.build(chatId: group, at: at, keyPayload: autoPayload, publisherId: admin))
        XCTAssertTrue(G2.isG2(wire))
        XCTAssertTrue(Rekey.isControlMessage(wire))
    }

    func testRejectsJunkRatherThanHalfParsingIt() {
        XCTAssertNil(G2.parse("G2:-1001:notanumber:x:42"))
        XCTAssertNil(G2.parse("G2:-1001:1:@@@:42"))
        XCTAssertNil(G2.parse("G2:-1001:1"))
        // A private chat id: `G2` is a group mechanism and nothing else (3.35.3)
        XCTAssertNil(G2.parse("G2:1001:1:AAAA:42"))
        XCTAssertFalse(G2.isG2("N1:-1001:42:1:auto::YWJj:YWJj"))
    }

    // PLAN.md 3.35.8 (2026-09-20 用户定). Read G2Obfuscation.swift before drawing conclusions from these:
    // the passphrase ships in every build, so this is obfuscation, not confidentiality.
    func testThePayloadIsNotReadableAsSecutgKeyOnTheWire() throws {
        let wire = try XCTUnwrap(G2.build(chatId: group, at: at, keyPayload: autoPayload, publisherId: admin))
        XCTAssertFalse(wire.contains(KeyPayload.prefix))
        XCTAssertFalse(wire.contains("secutg"))
    }

    func testTwoBroadcastsOfTheSameKeyDifferOnTheWire() throws {
        // A fresh nonce each time, so a stock client cannot match two groups' broadcasts to each other and
        // conclude they share a key.
        let a = try XCTUnwrap(G2.build(chatId: group, at: at, keyPayload: autoPayload, publisherId: admin))
        let b = try XCTUnwrap(G2.build(chatId: group, at: at, keyPayload: autoPayload, publisherId: admin))
        XCTAssertNotEqual(a, b)
    }

    func testATamperedPayloadFailsTheTag() throws {
        let wire = try XCTUnwrap(G2.build(chatId: group, at: at, keyPayload: autoPayload, publisherId: admin))
        var parts = wire.components(separatedBy: ":")
        let seg = parts[3]
        parts[3] = String(seg.dropLast()) + (seg.hasSuffix("A") ? "B" : "A")
        XCTAssertNil(G2.parse(parts.joined(separator: ":")))
    }

    // MARK: judge (PLAN.md 3.35.4)

    func testAFreshBroadcastFromAKnownAdminIsApplied() {
        XCTAssertEqual(G2.judge(at: at, boundAt: nil, publisherIsAdmin: true, payloadMode: .auto, isOwn: false), .apply)
    }

    func testNewestWins() {
        XCTAssertEqual(G2.judge(at: 200, boundAt: 100, publisherIsAdmin: true, payloadMode: .auto, isOwn: false), .apply)
    }

    func testTheWholeReplayRule() {
        // This is all that is left of 3.34.3's anchor machinery in auto mode. Scrolling back through history
        // re-reads every past broadcast; none of them may unseat the current key.
        XCTAssertEqual(G2.judge(at: 100, boundAt: 200, publisherIsAdmin: true, payloadMode: .auto, isOwn: false), .stale)
        XCTAssertEqual(G2.judge(at: 100, boundAt: 100, publisherIsAdmin: true, payloadMode: .auto, isOwn: false), .stale)
    }

    func testAnUnknownPublisherParksItDoesNotRefuse() {
        // The admin list is async. Refusing here is exactly the bug that made four batches fail: the member
        // sees nothing and waits forever.
        XCTAssertEqual(G2.judge(at: at, boundAt: nil, publisherIsAdmin: nil, payloadMode: .auto, isOwn: false), .park)
    }

    func testANonAdminPublisherIsRefusedAndVisiblySo() {
        XCTAssertEqual(G2.judge(at: at, boundAt: nil, publisherIsAdmin: false, payloadMode: .auto, isOwn: false), .refuseNotAdmin)
    }

    func testAManualModePayloadIsRefused() {
        XCTAssertEqual(G2.judge(at: at, boundAt: nil, publisherIsAdmin: true, payloadMode: .manual, isOwn: false), .refuseNotAuto)
    }

    func testThisDevicePublishedIt() {
        XCTAssertEqual(G2.judge(at: at, boundAt: nil, publisherIsAdmin: true, payloadMode: .auto, isOwn: true), .own)
    }

    func testNothingIsEverSilent() {
        var seen = Set<G2.Verdict>()
        for at in [Int64(100), Int64(200)] {
            for boundAt in [nil, Int64(100), Int64(200)] as [Int64?] {
                for admin in [true, false, nil] as [Bool?] {
                    for mode in [Rekey.KeyMode.auto, .manual] {
                        for own in [true, false] {
                            seen.insert(G2.judge(at: at, boundAt: boundAt, publisherIsAdmin: admin,
                                                 payloadMode: mode, isOwn: own))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(seen.count, G2.Verdict.allCases.count)
    }

    func testThePublisherGateIsCheckedBeforeTheClock() {
        // Otherwise a parked broadcast would be judged `stale` on the retry that finally knows the publisher —
        // the anchor bug of 3.34.3 rule 3, reintroduced by ordering.
        XCTAssertEqual(G2.judge(at: 100, boundAt: 200, publisherIsAdmin: nil, payloadMode: .auto, isOwn: false), .park)
    }
}
