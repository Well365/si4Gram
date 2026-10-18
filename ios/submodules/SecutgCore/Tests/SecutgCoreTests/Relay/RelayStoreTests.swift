import XCTest
@testable import SecutgCore

final class RelayStoreTests: XCTestCase {
    func testAppStateDefaultsToEmptyThenPersists() {
        let backing = RelayMemoryAppStore()
        let state = RelayAppState(store: backing)
        XCTAssertEqual(state.current, .empty)

        state.update { config in
            config.settings.enabled = true
            config.relays.append(RelayEndpoint(id: "r1", urlString: "https://relay.example.com", token: "tok", isDefault: true))
        }
        XCTAssertEqual(backing.saved?.settings.enabled, true)
        XCTAssertEqual(backing.saved?.relays.first?.id, "r1")

        // A new state wrapper over the same backing store picks up what was saved.
        let reloaded = RelayAppState(store: backing)
        XCTAssertEqual(reloaded.current.settings.enabled, true)
    }

    func testAppStateWipeClearsBackingStore() {
        let backing = RelayMemoryAppStore(.init(settings: .default, relays: [RelayEndpoint(urlString: "https://r", token: nil, isDefault: true)], trustedHosts: []))
        let state = RelayAppState(store: backing)
        state.wipeForEmergencyWipe()
        XCTAssertNil(backing.saved?.relays.first)
        XCTAssertEqual(state.current, .empty)
    }

    func testTrustingIsIdempotent() {
        let config = RelayAppConfig.empty.trusting(urlString: "https://r", atMs: 1).trusting(urlString: "https://r", atMs: 2)
        XCTAssertEqual(config.trustedHosts.count, 1)
        XCTAssertEqual(config.trustedHosts.first?.trustedAtMs, 1)
        XCTAssertTrue(config.isTrusted(urlString: "https://r"))
        XCTAssertFalse(config.isTrusted(urlString: "https://other"))
    }

    func testAccountStateSentItemsAndRevoke() {
        let backing = RelayMemoryAccountStore()
        let state = RelayAccountState(store: backing)
        let item = RelaySentItem(id: "i1", chatId: "c1", messageId: 10, relayURL: "https://r", deleteToken: "dtok", contentType: .text, keepPolicy: .default, createdAtMs: 0)
        state.recordSentItem(item)
        XCTAssertEqual(state.sentItem(id: "i1")?.chatId, "c1")
        XCTAssertEqual(state.sentItem(chatId: "c1", messageId: 10)?.id, "i1")

        state.markRevoked(id: "i1")
        XCTAssertEqual(state.sentItem(id: "i1")?.revoked, true)
        XCTAssertEqual(backing.saved?.sentItems.first?.revoked, true)
    }

    func testAccountStateLocalCopyRoundTripAndRemoval() {
        let backing = RelayMemoryAccountStore()
        let state = RelayAccountState(store: backing)
        let copy = RelayLocalCopy(chatId: "c1", messageId: 5, contentType: .text, mime: "text/plain;charset=utf-8", text: "hi", imageData: nil, savedAtMs: 0, direction: .received)
        state.saveLocalCopy(copy)
        XCTAssertEqual(state.localCopy(chatId: "c1", messageId: 5), copy)

        state.removeLocalCopy(chatId: "c1", messageId: 5)
        XCTAssertNil(state.localCopy(chatId: "c1", messageId: 5))
        XCTAssertTrue(backing.saved?.localCopies.isEmpty ?? false)
    }

    func testAccountStateRemoveLocalCopiesBatch() {
        let backing = RelayMemoryAccountStore()
        let state = RelayAccountState(store: backing)
        state.saveLocalCopy(RelayLocalCopy(chatId: "c1", messageId: 1, contentType: .text, mime: "text/plain;charset=utf-8", text: "a", imageData: nil, savedAtMs: 0, direction: .sent))
        state.saveLocalCopy(RelayLocalCopy(chatId: "c1", messageId: 2, contentType: .text, mime: "text/plain;charset=utf-8", text: "b", imageData: nil, savedAtMs: 0, direction: .sent))
        state.removeLocalCopies(chatId: "c1", messageIds: [1, 2])
        XCTAssertEqual(backing.saved?.localCopies.count, 0)
    }

    func testAccountStateChatPolicyDefaultsToFollowGlobal() {
        let state = RelayAccountState(store: RelayMemoryAccountStore())
        XCTAssertEqual(state.chatPolicy(chatId: "c1"), .default)
        state.setChatPolicy(chatId: "c1", policy: RelayChatPolicy(mode: .alwaysOn, keepPolicy: nil, relayId: nil))
        XCTAssertEqual(state.chatPolicy(chatId: "c1").mode, .alwaysOn)
    }

    func testAccountStateWipeAllClearsSentItemsAndLocalCopies() {
        let backing = RelayMemoryAccountStore()
        let state = RelayAccountState(store: backing)
        state.recordSentItem(RelaySentItem(id: "i1", chatId: "c1", messageId: 1, relayURL: "https://r", deleteToken: nil, contentType: .text, keepPolicy: .default, createdAtMs: 0))
        state.saveLocalCopy(RelayLocalCopy(chatId: "c1", messageId: 1, contentType: .text, mime: "text/plain;charset=utf-8", text: "a", imageData: nil, savedAtMs: 0, direction: .sent))
        state.wipeAll()
        XCTAssertEqual(state.current, .empty)
        XCTAssertNil(backing.saved?.sentItems.first)
    }

    /// Exercises the real Keychain + file backend, matching how `V2PersistTests` covers `V2KeychainStorage`.
    func testKeychainBackedAppStoreRoundTripAndWipe() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-app-test-\(UUID().uuidString)")
        let store = RelayKeychainAppStore(basePath: dir.path)
        defer { store.wipe(); try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(store.load())
        var config = RelayAppConfig.empty
        config.settings.enabled = true
        config.relays = [RelayEndpoint(id: "r1", urlString: "https://relay.example.com", token: "tok", isDefault: true)]
        store.save(config)
        XCTAssertEqual(store.load(), config)

        store.wipe()
        XCTAssertNil(store.load())
    }

    func testKeychainBackedAccountStoreIsolatesAccounts() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-acct-test-\(UUID().uuidString)")
        let storeA = RelayKeychainAccountStore(accountKey: "acct-a-\(UUID().uuidString)", basePath: dir.path)
        let storeB = RelayKeychainAccountStore(accountKey: "acct-b-\(UUID().uuidString)", basePath: dir.path)
        defer { storeA.wipe(); storeB.wipe(); try? FileManager.default.removeItem(at: dir) }

        var snapshotA = RelayAccountSnapshot.empty
        snapshotA.sentItems = [RelaySentItem(id: "i1", chatId: "c1", messageId: 1, relayURL: "https://r", deleteToken: nil, contentType: .text, keepPolicy: .default, createdAtMs: 0)]
        storeA.save(snapshotA)

        XCTAssertEqual(storeA.load()?.sentItems.count, 1)
        XCTAssertNil(storeB.load())

        storeA.wipe()
        XCTAssertNil(storeA.load())
    }
}
