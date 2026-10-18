import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.46.1 step 3: the "shown codes" record and the list of chats a lost device may still read.
final class LostDeviceGuideTests: XCTestCase {
    private typealias Code = LostDeviceGuide.ShownCode
    private typealias Row = LostDeviceGuide.AffectedChat

    // MARK: the record

    func testRecordingKeepsOneEntryPerChatNewestFirst() {
        var list: [Code] = []
        list = LostDeviceGuide.recording(list, chatId: "1", atMs: 10)
        list = LostDeviceGuide.recording(list, chatId: "2", atMs: 20)
        list = LostDeviceGuide.recording(list, chatId: "1", atMs: 30)
        XCTAssertEqual(list, [Code(chatId: "1", atMs: 30), Code(chatId: "2", atMs: 20)])
        XCTAssertEqual(LostDeviceGuide.recording(list, chatId: "", atMs: 99), list)
    }

    func testRecordingIsCappedNewestKept() {
        var list: [Code] = []
        for i in 0..<205 { list = LostDeviceGuide.recording(list, chatId: "\(1000 + i)", atMs: Int64(i)) }
        XCTAssertEqual(list.count, LostDeviceGuide.maxShownCodes)
        XCTAssertEqual(list.first, Code(chatId: "1204", atMs: 204))
        XCTAssertEqual(list.last, Code(chatId: "1005", atMs: 5))
        XCTAssertEqual(LostDeviceGuide.recording([], chatId: "1", atMs: 1, cap: 0), [])
    }

    func testRoundTrip() {
        let list = [Code(chatId: "2", atMs: 20), Code(chatId: "1", atMs: 10)]
        let text = LostDeviceGuide.serializeShownCodes(list)
        XCTAssertEqual(text, "[{\"at\":20,\"chat\":\"2\"},{\"at\":10,\"chat\":\"1\"}]")
        XCTAssertEqual(LostDeviceGuide.parseShownCodes(text), list)
        XCTAssertEqual(LostDeviceGuide.serializeShownCodes([]), "[]")
    }

    func testUnreadableRecordReadsAsEmptyAndBadEntriesDrop() {
        for text in [nil, "", "{}", "not json", "[1,2]"] {
            XCTAssertEqual(LostDeviceGuide.parseShownCodes(text), [], text ?? "nil")
        }
        let parsed = LostDeviceGuide.parseShownCodes("[{\"chat\":\"1\",\"at\":5},{\"chat\":\"\",\"at\":6},{\"chat\":\"2\",\"at\":true},{\"chat\":\"3\",\"at\":1.5},{\"at\":7},{\"chat\":\"1\",\"at\":9}]")
        XCTAssertEqual(parsed, [Code(chatId: "1", atMs: 9)])
    }

    func testStorageKeyIsPerAccount() {
        XCTAssertEqual(LostDeviceGuide.shownCodesKey(accountKey: "42"), "secutg.lostDevice.shownCodes.42")
    }

    // MARK: step 3

    func testAffectedChatsUnionBothSources() {
        let rows = LostDeviceGuide.affectedChats(
            importedChatIds: ["300", "100", "-5", "42"],
            shownCodes: [Code(chatId: "200", atMs: 5), Code(chatId: "100", atMs: 9), Code(chatId: "-1000000000123", atMs: 50), Code(chatId: "42", atMs: 60)],
            ownUserId: "42")
        XCTAssertEqual(rows, [
            Row(chatId: "100", imported: true, shownAtMs: 9),
            Row(chatId: "200", imported: false, shownAtMs: 5),
            Row(chatId: "300", imported: true, shownAtMs: nil),
        ])
    }

    func testAffectedChatsEmpty() {
        XCTAssertEqual(LostDeviceGuide.affectedChats(importedChatIds: [], shownCodes: [], ownUserId: "1"), [])
    }

    func testImportedChatIdsReadTheClonedBindingsOnly() {
        XCTAssertEqual(LostDeviceGuide.importedChatIds(v2: nil), [])
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        let stored = KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
        let runtime = V2Runtime(identity: V2IdentityBridge.identity(userId: "1", from: stored)!,
                                persisted: V2PersistedState.load(storage: V2MemoryStorage()))
        func install(_ chatId: String, txnId: String) {
            runtime.pairing.bindingStore.install(V2Binding.freshTemplate(
                chatId: chatId, bindingId: "b" + chatId, epoch: 1, deviceRoster: [], deviceKeys: [:],
                revision: 1, txnId: txnId, installedAtMs: 1))
        }
        install("500", txnId: V2JoinCoordinator.cloneTxnPrefix + "b500")
        install("400", txnId: "join:x")
        install("600", txnId: "plain-pairing")
        XCTAssertEqual(LostDeviceGuide.importedChatIds(v2: runtime), ["400", "500"])
    }
}
