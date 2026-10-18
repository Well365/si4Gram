import XCTest
@testable import SecutgCore

/// Review 2026-09-30: the switch file cannot be forged without the Keychain secret, key material never reads as
/// words, and a `chat_peer_id` that Postbox's `PeerId(_:)` would assert on is refused before it gets there.
final class AssistantSafetyTests: XCTestCase {
    private let key = [UInt8](repeating: 7, count: 32)
    private let otherKey = [UInt8](repeating: 9, count: 32)

    // MARK: switch marker

    func testMarkerMadeWithTheKeyIsValidForItsAccountOnly() {
        let content = AssistantSwitchMarker.adding(account: 111, key: key, to: nil)
        XCTAssertTrue(AssistantSwitchMarker.isValid(content, account: 111, key: key))
        XCTAssertFalse(AssistantSwitchMarker.isValid(content, account: 222, key: key))
        XCTAssertFalse(AssistantSwitchMarker.isValid(content, account: 111, key: otherKey))
    }

    func testForgedOrLegacyFilesReadAsOff() {
        for content in ["", "1\n", "v1 111 00\n", "v1 111\n", "v1 111 \(String(repeating: "0", count: 64))\n", "garbage"] {
            XCTAssertFalse(AssistantSwitchMarker.isValid(content, account: 111, key: key), content)
        }
        XCTAssertFalse(AssistantSwitchMarker.isValid(nil, account: 111, key: key))
        XCTAssertNil(AssistantSwitchMarker.tag(account: 111, key: [1, 2, 3]))
    }

    func testRotatedKeyInvalidatesACopiedMarker() {
        let copied = AssistantSwitchMarker.adding(account: 111, key: key, to: nil)
        XCTAssertFalse(AssistantSwitchMarker.isValid(copied, account: 111, key: otherKey))
    }

    func testAddingAndRemovingKeepOtherAccountsLines() {
        let both = AssistantSwitchMarker.adding(account: 222, key: otherKey, to: AssistantSwitchMarker.adding(account: 111, key: key, to: "1\n"))
        XCTAssertTrue(AssistantSwitchMarker.isValid(both, account: 111, key: key))
        XCTAssertTrue(AssistantSwitchMarker.isValid(both, account: 222, key: otherKey))
        XCTAssertEqual(both?.split(separator: "\n").count, 2)
        let rewritten = AssistantSwitchMarker.adding(account: 111, key: otherKey, to: both)
        XCTAssertEqual(rewritten?.split(separator: "\n").count, 2)
        XCTAssertTrue(AssistantSwitchMarker.isValid(rewritten, account: 111, key: otherKey))
        let left = AssistantSwitchMarker.removing(account: 111, from: rewritten)
        XCTAssertFalse(AssistantSwitchMarker.isValid(left, account: 111, key: otherKey))
        XCTAssertTrue(AssistantSwitchMarker.isValid(left, account: 222, key: otherKey))
        XCTAssertNil(AssistantSwitchMarker.removing(account: 222, from: left))
    }

    // MARK: key material

    func testKeyMaterialIsRecognisedWhateverItsMeta() throws {
        let payload = KeyPayload.build(masterKey: [UInt8](repeating: 1, count: 32), adminPk: nil)
        let invite = try GroupInvite.build(GroupInvite(groupChatId: "-1001234", keyPayload: payload, title: "T"))
        XCTAssertTrue(AssistantPlaceholder.carriesKeyMaterial(invite))
        XCTAssertTrue(AssistantPlaceholder.carriesKeyMaterial("see " + payload))
        XCTAssertTrue(AssistantPlaceholder.carriesKeyMaterial(" G1:-1:x:y"))
        for prefix in [TransferBundle.prefix, QuickShare.prefix, V2JoinText.prefix] {
            XCTAssertTrue(AssistantPlaceholder.carriesKeyMaterial(prefix + "abc"), prefix)
        }
        XCTAssertFalse(AssistantPlaceholder.carriesKeyMaterial("@me 看下 PROJ-123"))
        XCTAssertFalse(AssistantPlaceholder.carriesKeyMaterial("secutg:// is our scheme"))
    }

    // MARK: peer ids

    func testChatPeerIdsPostboxCanHold() {
        let user: Int64 = 123_456_789                          // namespace 0
        let group: Int64 = (1 << 32) | 4242                    // namespace 1
        let channel: Int64 = (2 << 32) | 1_234_567_890         // namespace 2
        let bigUser: Int64 = (Int64(1) << 35) | 5              // id 2^32 + 5, namespace 0
        for raw in [user, group, channel, bigUser] { XCTAssertTrue(AssistantProtocol.isCloudChatPeerId(raw), "\(raw)") }
    }

    func testIdsPostboxWouldAssertOnAreRefused() {
        let secret: Int64 = (3 << 32) | 1
        let tooWide: Int64 = Int64(bitPattern: (UInt64(1) << 24) << 35)  // id high bits past 56 bits
        for raw in [-1, -123, -1_001_234_567_890, Int64.min, Int64.max, 0, secret, tooWide] {
            XCTAssertFalse(AssistantProtocol.isCloudChatPeerId(raw), "\(raw)")
        }
    }
}
