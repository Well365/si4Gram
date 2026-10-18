import XCTest
@testable import SecutgCore

/// The assistant's 自定义分组 = Telegram chat folders (2026-10-08): the pure part of `folder_update`.
final class AssistantFoldersTests: XCTestCase {
    func testPeersPerAction() {
        XCTAssertEqual(AssistantFolderEdit.peers(current: [1, 2], action: .add, peerIds: [2, 3]), [1, 2, 3])
        XCTAssertEqual(AssistantFolderEdit.peers(current: [1, 2, 3], action: .remove, peerIds: [2, 9]), [1, 3])
        XCTAssertEqual(AssistantFolderEdit.peers(current: [1, 2], action: .set, peerIds: [3]), [3])
        XCTAssertEqual(AssistantFolderEdit.peers(current: [], action: .create, peerIds: [4, 5]), [4, 5])
        XCTAssertNil(AssistantFolderEdit.peers(current: [1], action: .rename, peerIds: []))
        XCTAssertNil(AssistantFolderEdit.peers(current: [1], action: .delete, peerIds: []))
    }

    func testRefusals() {
        XCTAssertEqual(AssistantFolderEdit.refusal(action: .add, folderIsShared: true, resultingCount: 1)?.code, .refused)
        XCTAssertEqual(AssistantFolderEdit.refusal(action: .delete, folderIsShared: true, resultingCount: nil)?.code, .refused)
        XCTAssertEqual(AssistantFolderEdit.refusal(action: .add, folderIsShared: false, resultingCount: 201)?.code, .tooLong)
        XCTAssertNil(AssistantFolderEdit.refusal(action: .add, folderIsShared: false, resultingCount: 200))
        XCTAssertNil(AssistantFolderEdit.refusal(action: .rename, folderIsShared: false, resultingCount: nil))
    }

    func testJSON() {
        let folder = AssistantFolder(id: 5, title: "后端", emoticon: nil, peerIds: [9, 8], hasRules: true, shared: false)
        XCTAssertEqual(folder.json, .object(["id": .int(5), "title": .string("后端"), "emoticon": .null,
                                             "peer_ids": .array([.int(9), .int(8)]), "has_rules": .bool(true), "shared": .bool(false)]))
        XCTAssertEqual(AssistantResults.folderDeleted(id: 5), ["deleted": .int(5)])
    }
}
