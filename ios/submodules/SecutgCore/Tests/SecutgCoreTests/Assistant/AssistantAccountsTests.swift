import XCTest
@testable import SecutgCore

/// PLAN.md 3.45.2 amendment 2026-10-02: several accounts on one Mac — what the socket does, and the account list.
final class AssistantAccountsTests: XCTestCase {
    func testModeFollowsTheActiveAccountsSwitch() {
        XCTAssertEqual(AssistantInterfaceMode.decide(hasActiveAccount: true, activeAccountEnabled: true, anyLoggedInAccountEnabled: true), .serving)
        XCTAssertEqual(AssistantInterfaceMode.decide(hasActiveAccount: true, activeAccountEnabled: true, anyLoggedInAccountEnabled: false), .serving)
        // The 2026-10-02 report: the active account is off, another one is on → status only, not silence.
        XCTAssertEqual(AssistantInterfaceMode.decide(hasActiveAccount: true, activeAccountEnabled: false, anyLoggedInAccountEnabled: true), .statusOnly)
        XCTAssertEqual(AssistantInterfaceMode.decide(hasActiveAccount: true, activeAccountEnabled: false, anyLoggedInAccountEnabled: false), .off)
        XCTAssertEqual(AssistantInterfaceMode.decide(hasActiveAccount: false, activeAccountEnabled: true, anyLoggedInAccountEnabled: true), .off)
    }

    func testStatusOnlyAnswersHelloAndStatusAlone() {
        let allowed = AssistantOp.allCases.filter { AssistantInterfaceMode.statusOnly.allows($0) }
        XCTAssertEqual(allowed, [.hello, .status])
        XCTAssertEqual(AssistantOp.allCases.filter { AssistantInterfaceMode.serving.allows($0) }, AssistantOp.allCases)
        XCTAssertTrue(AssistantOp.allCases.allSatisfy { !AssistantInterfaceMode.off.allows($0) })
        XCTAssertEqual(AssistantInterfaceMode.notServingFailure.code, .notReady)
    }

    func testEveryCommandNamesItsOp() {
        let commands: [AssistantCommand] = [
            .hello(client: "c", version: "1"), .status, .directory, .subscribe(since: 0), .ack(seq: 1),
            .context(chatPeerId: 1, messageId: 1, before: 0, after: 0),
            .send(chatPeerId: 1, text: "x", replyToMessageId: nil, encryption: .follow), .read(chatPeerId: 1, messageId: 1),
            .open(chatPeerId: 1, messageId: nil, accountPeerId: nil), .history(chatPeerId: 1, since: 0, limit: 1),
            .folders, .folderUpdate(action: .delete, folderId: 2, title: nil, peerIds: []),
            .media(chatPeerId: 1, messageId: 1, index: 0, maxBytes: 1),
        ]
        XCTAssertEqual(commands.map { $0.op }, AssistantOp.allCases)
    }

    func testListMarksOneActiveRowAndDropsRepeats() {
        let max = AssistantPerson(peerId: 11, telegramId: 11, name: "max well", username: "super42")
        let rob = AssistantPerson(peerId: 22, telegramId: 22, name: "Rob3.1415926", username: nil)
        let rows = AssistantAccountEntry.list([(max, true), (rob, false), (max, false)], activePeerId: 22)
        XCTAssertEqual(rows.map { $0.person.peerId }, [11, 22])
        XCTAssertEqual(rows.map { $0.active }, [false, true])
        XCTAssertEqual(rows.map { $0.captureEnabled }, [true, false])
        XCTAssertEqual(rows[1].json, .object(["peer_id": .int(22), "telegram_id": .int(22), "name": .string("Rob3.1415926"),
                                              "username": .null, "active": .bool(true), "capture_enabled": .bool(false)]))
        XCTAssertTrue(AssistantAccountEntry.list([(max, true)], activePeerId: nil).allSatisfy { !$0.active })
    }

    func testStatusCarriesTheAccountFields() {
        let max = AssistantPerson(peerId: 11, telegramId: 11, name: "max well", username: "super42")
        let empty = AssistantResults.status(AssistantResults.Status(account: nil, online: false, captureEnabled: false, queuePending: 0,
                                                                    dropped: 0, lastEventSeq: 0, lastRescanAt: nil, build: "b"))
        XCTAssertEqual(empty["accounts"], .array([]))
        XCTAssertEqual(empty["active_account_peer_id"], .null)
        let one = AssistantResults.status(AssistantResults.Status(account: max, online: true, captureEnabled: false, queuePending: 0,
                                                                  dropped: 0, lastEventSeq: 0, lastRescanAt: nil, build: "b",
                                                                  accounts: AssistantAccountEntry.list([(max, false)], activePeerId: 11),
                                                                  activeAccountPeerId: 11))
        XCTAssertEqual(one["active_account_peer_id"], .int(11))
        XCTAssertEqual(one["accounts"]?.arrayValue?.first?["capture_enabled"], .bool(false))
    }

    func testEventsCarryTheReceivingAccountOnlyWhenKnown() {
        let me = AssistantPerson(peerId: 11, telegramId: 11, name: "me", username: nil)
        let chat = AssistantChat(peerId: 11, telegramId: 11, kind: .user, title: "me", username: nil, encryption: .v2)
        let message = AssistantMessage(id: 5, date: 1, sender: me, text: "/secu status", entities: [], wasEncrypted: true, replyToMessageId: nil)
        let command = AssistantCommandEvent(seq: 1, atMs: 1000, chat: chat, message: message, command: SelfCommand.parse("/secu status")!,
                                            accountPeerId: 11)
        XCTAssertEqual(command.data["account_peer_id"], .int(11))
        let old = AssistantCommandEvent(seq: 1, atMs: 1000, chat: chat, message: message, command: SelfCommand.parse("/secu status")!)
        XCTAssertNil(old.data["account_peer_id"])
        let mention = AssistantMentionEvent(seq: 2, atMs: 1000, chat: chat, message: message,
                                            mention: AssistantMention(kind: .name, offset: 0, length: 2), replyChain: [],
                                            contextBefore: [], accountPeerId: 11)
        var updated = mention
        updated.contextAfter = [message]
        XCTAssertEqual(updated.data["account_peer_id"], .int(11))
    }
}
