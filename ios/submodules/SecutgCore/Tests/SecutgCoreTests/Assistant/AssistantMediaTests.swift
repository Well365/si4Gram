import XCTest
@testable import SecutgCore

/// 2026-10-10: the assistant reads a chat's pictures — the `media` field on messages and the `media` op's pure part.
final class AssistantMediaTests: XCTestCase {
    static let sender = AssistantPerson(peerId: 1, telegramId: 1, name: "A", username: nil)

    func testItemJSON() {
        let photo = AssistantMediaItem(index: 0, kind: .photo, mime: "image/jpeg", size: 123_456, width: 1280, height: 960)
        XCTAssertEqual(photo.json, .object(["index": .int(0), "kind": .string("photo"), "mime": .string("image/jpeg"),
                                            "size": .int(123_456), "width": .int(1280), "height": .int(960)]))
        let file = AssistantMediaItem(index: 1, kind: .document, mime: "application/pdf", size: nil, width: nil, height: nil,
                                      fileName: "报告.pdf")
        XCTAssertEqual(file.json, .object(["index": .int(1), "kind": .string("document"), "mime": .string("application/pdf"),
                                           "size": .null, "width": .null, "height": .null, "file_name": .string("报告.pdf")]))
        XCTAssertEqual(AssistantMediaKind.allCases.map { $0.rawValue }, ["photo", "document", "video", "sticker"])
    }

    /// Old fields never change: a message without attachments has no `media` key at all.
    func testMessageCarriesMediaOnlyWhenThereIsSome() {
        let plain = AssistantMessage(id: 1, date: 2, sender: Self.sender, text: "hi", entities: [], wasEncrypted: false, replyToMessageId: nil)
        XCTAssertNil(plain.json["media"])
        let item = AssistantMediaItem(index: 0, kind: .photo, mime: "image/jpeg", size: 10, width: 1, height: 1)
        let withPhoto = AssistantMessage(id: 1, date: 2, sender: Self.sender, text: AssistantPlaceholder.photo.rawValue, entities: [],
                                         wasEncrypted: false, replyToMessageId: nil, media: [item])
        XCTAssertEqual(withPhoto.json["media"], .array([item.json]))
        XCTAssertEqual(withPhoto.json["text"], .string("[图片]"))
    }

    func testOnlyPicturesAreServed() {
        XCTAssertTrue(AssistantMediaPolicy.isServable(kind: .photo, mime: "image/jpeg"))
        XCTAssertTrue(AssistantMediaPolicy.isServable(kind: .document, mime: "image/PNG"))
        XCTAssertTrue(AssistantMediaPolicy.isServable(kind: .document, mime: "image/webp"))
        XCTAssertFalse(AssistantMediaPolicy.isServable(kind: .document, mime: "image/svg+xml"))
        XCTAssertFalse(AssistantMediaPolicy.isServable(kind: .document, mime: "application/pdf"))
        XCTAssertFalse(AssistantMediaPolicy.isServable(kind: .video, mime: "video/mp4"))
        XCTAssertFalse(AssistantMediaPolicy.isServable(kind: .sticker, mime: "image/webp"))
    }

    func testSizeRefusal() {
        XCTAssertNil(AssistantMediaPolicy.sizeRefusal(size: nil, maxBytes: 10))
        XCTAssertNil(AssistantMediaPolicy.sizeRefusal(size: 10, maxBytes: 10))
        XCTAssertEqual(AssistantMediaPolicy.sizeRefusal(size: 11, maxBytes: 10)?.code, .tooLarge)
    }

    func testResult() {
        let data = Data("abc".utf8)
        XCTAssertEqual(AssistantResults.media(mime: "image/png", data: data), [
            "mime": .string("image/png"), "size": .int(3),
            "sha256": .string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            "data_base64": .string("YWJj"),
        ])
    }

    /// The largest answer `media` can give still fits the assistant's 16 MiB line.
    func testCeilingFitsTheAssistantsLine() {
        let base64 = (AssistantProtocol.maxMediaBytes + 2) / 3 * 4
        XCTAssertLessThan(base64 + 1024, 16 * 1024 * 1024)
    }
}
