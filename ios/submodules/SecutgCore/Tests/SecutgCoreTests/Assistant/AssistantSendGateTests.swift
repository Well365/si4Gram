import XCTest
@testable import SecutgCore

/// Implementation plan C1.8: each gate refusal maps to its error code, in the order the send path meets them.
final class AssistantSendGateTests: XCTestCase {
    private func code(_ facts: AssistantSendGate.Facts) -> AssistantErrorCode? {
        return AssistantSendGate.refusal(facts)?.code
    }

    func testOrdinaryPlainChatPasses() {
        XCTAssertNil(code(.init(utf16Length: 5)))
    }

    func testEncryptingChatWithKeyPasses() {
        XCTAssertNil(code(.init(utf16Length: 5, encrypts: true, hasSendKey: true, maxPlaintextLength: 4096)))
    }

    func testGroupPasswordLockedIsLocked() {
        XCTAssertEqual(code(.init(utf16Length: 5, groupPasswordLocked: true, keyRequiredRefuses: true)), .locked)
    }

    func testKeyRequiredIsNoKey() {
        XCTAssertEqual(code(.init(utf16Length: 5, keyRequiredRefuses: true)), .noKey)
    }

    func testEncryptingChatWithoutKeyIsNoKey() {
        XCTAssertEqual(code(.init(utf16Length: 5, encrypts: true, hasSendKey: false)), .noKey)
    }

    func testUnknownEncryptionStateIsRefused() {
        XCTAssertEqual(code(.init(utf16Length: 5, encryptionStateUnknown: true)), .refused)
    }

    func testReservedTextIsRefusedBeforeAnyChatGate() {
        XCTAssertEqual(code(.init(utf16Length: 5, isReservedText: true, groupPasswordLocked: true)), .refused)
    }

    func testLengths() {
        XCTAssertEqual(code(.init(utf16Length: 4097)), .tooLong)
        XCTAssertEqual(code(.init(utf16Length: 3000, encrypts: true, hasSendKey: true, maxPlaintextLength: 2000)), .tooLong)
        XCTAssertNil(code(.init(utf16Length: 3000, encrypts: false, maxPlaintextLength: 2000)))
    }

    // MARK: encryption: encrypted / plaintext (phase 2, C2.1)

    private func code(_ facts: AssistantSendGate.Facts, _ mode: AssistantSendEncryption) -> AssistantErrorCode? {
        return AssistantSendGate.refusal(facts, encryption: mode)?.code
    }

    func testFollowIsTheDefault() {
        let cases: [AssistantSendGate.Facts] = [
            .init(utf16Length: 5), .init(utf16Length: 5, keyRequiredRefuses: true),
            .init(utf16Length: 5, encryptionStateUnknown: true), .init(utf16Length: 5, encrypts: true, hasSendKey: false),
            .init(utf16Length: 5, groupPasswordLocked: true),
        ]
        for facts in cases { XCTAssertEqual(code(facts), code(facts, .follow)) }
    }

    func testEncryptedNeedsOnlyAKey() {
        // The chat's switch is off but a key is there: encrypted may go.
        XCTAssertNil(code(.init(utf16Length: 5, encrypts: false, hasSendKey: true, maxPlaintextLength: 4096), .encrypted))
        XCTAssertNil(code(.init(utf16Length: 5, encrypts: true, hasSendKey: true, maxPlaintextLength: 4096), .encrypted))
        XCTAssertEqual(code(.init(utf16Length: 5, encrypts: false, hasSendKey: false), .encrypted), .noKey)
        XCTAssertEqual(code(.init(utf16Length: 5, keyRequiredRefuses: true, hasSendKey: false, keyRequired: true), .encrypted), .noKey)
        XCTAssertEqual(code(.init(utf16Length: 5, groupPasswordLocked: true, hasSendKey: true), .encrypted), .locked)
        XCTAssertEqual(code(.init(utf16Length: 3000, hasSendKey: true, maxPlaintextLength: 2000), .encrypted), .tooLong)
        XCTAssertEqual(code(.init(utf16Length: 5, isReservedText: true, hasSendKey: true), .encrypted), .refused)
        // An unknown switch state does not matter when the message is encrypted regardless.
        XCTAssertNil(code(.init(utf16Length: 5, encryptionStateUnknown: true, hasSendKey: true), .encrypted))
    }

    func testPlaintextOnlyWhereTheChatIsPlainAnyway() {
        XCTAssertNil(code(.init(utf16Length: 5), .plaintext))
        XCTAssertNil(code(.init(utf16Length: 3000, maxPlaintextLength: 2000), .plaintext))
        XCTAssertEqual(code(.init(utf16Length: 5, encrypts: true, hasSendKey: true), .plaintext), .refused)
        XCTAssertEqual(code(.init(utf16Length: 5, encrypts: true, hasSendKey: false), .plaintext), .refused)
        XCTAssertEqual(code(.init(utf16Length: 5, encryptionStateUnknown: true), .plaintext), .refused)
        XCTAssertEqual(code(.init(utf16Length: 5, keyRequired: true), .plaintext), .refused)
        XCTAssertEqual(code(.init(utf16Length: 5, keyRequiredRefuses: true), .plaintext), .refused)
        XCTAssertEqual(code(.init(utf16Length: 5, groupPasswordLocked: true), .plaintext), .refused)
        XCTAssertEqual(code(.init(utf16Length: 5, hasGroupPassword: true), .plaintext), .refused)
        XCTAssertEqual(code(.init(utf16Length: 5, isReservedText: true), .plaintext), .refused)
        XCTAssertEqual(code(.init(utf16Length: 4097), .plaintext), .tooLong)
    }

    func testPlaceholders() {
        XCTAssertEqual(AssistantPlaceholder.photo.rawValue, "[图片]")
        XCTAssertEqual(AssistantPlaceholder.control.rawValue, "[系统消息]")
        XCTAssertEqual(AssistantPlaceholder.withCaption(.photo, caption: " "), "[图片]")
        XCTAssertEqual(AssistantPlaceholder.withCaption(.file, caption: "spec.pdf"), "[文件] spec.pdf")
    }
}
