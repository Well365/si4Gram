import XCTest
@testable import SecutgCore

/// Implementation plan C1.4: three kinds of hit, four kinds of miss, case, several usernames, precedence.
final class MentionDetectorTests: XCTestCase {
    private let me: Int64 = 777

    private func detect(_ text: String, entities: [AssistantEntity] = [], usernames: [String] = ["Alice_Dev"],
                        names: [String] = ["张三"], senderIsSelf: Bool = false, isBot: Bool = false,
                        isChannel: Bool = false, wasEncrypted: Bool = false, fallback: Bool = true) -> AssistantMention? {
        return MentionDetector.detect(text: text, entities: entities, selfPeerId: me, selfUsernames: usernames,
                                      selfDisplayNames: names, senderIsSelf: senderIsSelf, isBot: isBot,
                                      isChannel: isChannel, wasEncrypted: wasEncrypted, fallbackEnabled: fallback)
    }

    // MARK: hits

    func testTextMentionOfSelf() {
        let text = "hi 张三 look"
        let hit = detect(text, entities: [AssistantEntity(type: "text_mention", offset: 3, length: 2, userPeerId: me)])
        XCTAssertEqual(hit, AssistantMention(kind: .entity, offset: 3, length: 2))
    }

    func testMentionEntityWithOwnUsernameAnyCase() {
        let text = "ping @alice_dev please"
        let hit = detect(text, entities: [AssistantEntity(type: "mention", offset: 5, length: 10)])
        XCTAssertEqual(hit, AssistantMention(kind: .username, offset: 5, length: 10))
    }

    func testSecondActiveUsernameCounts() {
        let text = "@Other_Me hi"
        let hit = detect(text, entities: [AssistantEntity(type: "mention", offset: 0, length: 9)], usernames: ["alice_dev", "@other_me"])
        XCTAssertEqual(hit?.kind, .username)
    }

    func testFallbackUsernameInEncryptedText() {
        let text = "看下 PROJ-1 @ALICE_DEV 谢谢"
        let hit = detect(text, wasEncrypted: true)
        XCTAssertEqual(hit, AssistantMention(kind: .username, offset: 10, length: 10))
    }

    func testFallbackDisplayNameInEncryptedText() {
        let text = "张三 看一下"
        XCTAssertEqual(detect(text, wasEncrypted: true), AssistantMention(kind: .name, offset: 0, length: 2))
    }

    func testFallbackLatinNameNeedsWordBoundary() {
        XCTAssertEqual(detect("hey tom, look", names: ["Tom"], wasEncrypted: true), AssistantMention(kind: .name, offset: 4, length: 3))
        XCTAssertNil(detect("tomorrow then", names: ["Tom"], wasEncrypted: true))
    }

    func testOffsetsAreUTF16() {
        let text = "🔒 @alice_dev"
        XCTAssertEqual(detect(text, wasEncrypted: true), AssistantMention(kind: .username, offset: 3, length: 10))
    }

    func testEntityBeatsUsernameBeatsName() {
        let text = "张三 @alice_dev 张三"
        let entities = [AssistantEntity(type: "mention", offset: 3, length: 10),
                        AssistantEntity(type: "text_mention", offset: 14, length: 2, userPeerId: me)]
        XCTAssertEqual(detect(text, entities: entities, wasEncrypted: true)?.kind, .entity)
        XCTAssertEqual(detect(text, entities: [entities[0]], wasEncrypted: true)?.kind, .username)
    }

    // MARK: misses

    func testOwnMessageIsNeverAHit() {
        XCTAssertNil(detect("@alice_dev", entities: [AssistantEntity(type: "mention", offset: 0, length: 10)], senderIsSelf: true))
    }

    func testBotIsNeverAHit() {
        XCTAssertNil(detect("@alice_dev", entities: [AssistantEntity(type: "mention", offset: 0, length: 10)], isBot: true))
    }

    func testChannelBroadcastIsNeverAHit() {
        XCTAssertNil(detect("@alice_dev", entities: [AssistantEntity(type: "mention", offset: 0, length: 10)], isChannel: true))
    }

    func testSomeoneElse() {
        XCTAssertNil(detect("@bob hi", entities: [AssistantEntity(type: "mention", offset: 0, length: 4)]))
        XCTAssertNil(detect("hi", entities: [AssistantEntity(type: "text_mention", offset: 0, length: 2, userPeerId: 1)]))
    }

    func testFallbackIsOffForPlainMessages() {
        XCTAssertNil(detect("@alice_dev 张三", wasEncrypted: false))
    }

    func testFallbackCanBeSwitchedOff() {
        XCTAssertNil(detect("@alice_dev 张三", wasEncrypted: true, fallback: false))
    }

    func testFallbackUsernameMustBeAWholeName() {
        XCTAssertNil(detect("@alice_devops", names: [], wasEncrypted: true))
        XCTAssertNil(detect("mail x@alice_dev", names: [], wasEncrypted: true))
    }

    func testShortNamesAreIgnored() {
        XCTAssertNil(detect("a b c", usernames: [], names: ["a"], wasEncrypted: true))
    }

    func testOutOfRangeEntityIsIgnored() {
        XCTAssertNil(detect("hi", entities: [AssistantEntity(type: "text_mention", offset: 1, length: 9, userPeerId: me)], names: []))
    }
}
