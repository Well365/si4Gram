import XCTest
@testable import SecutgCore

/// SECUTG-HOOK (fix, 2026-09-27): the emergency wipe destroys v2 state and nothing can write it back.
final class V2PersistedStateWipeTests: XCTestCase {
    func testWipeRemovesTheStoredStateAndLaterPersistsWriteNothing() {
        let storage = V2MemoryStorage()
        let state = V2PersistedState.load(storage: storage)
        state.incomingInviteStore.set("200", wire: "P2:x")
        state.persist()
        XCTAssertNotNil(storage.saved)

        state.wipe()
        XCTAssertTrue(state.isWiped)
        XCTAssertNil(storage.saved, "the stored state is gone")

        state.incomingInviteStore.set("300", wire: "P2:y")
        state.persist()
        XCTAssertNil(storage.saved, "a persist after the wipe writes nothing")
        XCTAssertNil(V2PersistedState.load(storage: storage).incomingInviteStore.get("200"))
    }
}
