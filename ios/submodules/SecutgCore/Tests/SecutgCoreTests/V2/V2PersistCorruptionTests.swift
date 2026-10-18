import XCTest
@testable import SecutgCore

/// Adversarial coverage for today's fix-E1 persistence/snapshot-restore code
/// (`V2Processor.InMemoryTxnStore`, `V2SelectionCas`, `V2PersistedState`, `V2KeychainStorage`):
/// malformed/truncated/corrupted data must fail closed — a decode error or an authentication failure,
/// never a crash and never silently accepted as valid state. `V2PersistTests` already covers the
/// GOOD-data round trip for every one of these stores; this file only adds BAD data.
final class V2PersistCorruptionTests: XCTestCase {
    // MARK: direct Codable decode of malformed/truncated JSON

    /// Mirrors the exact guard `V2KeychainStorage.load()` itself uses on a successfully-decrypted
    /// blob (`return try? JSONDecoder().decode(V2PersistedState.Snapshot.self, from: json)`): empty
    /// data, non-JSON bytes, JSON of the wrong shape, and a truncated-but-otherwise-real snapshot must
    /// all decode to `nil` via `try?`, never crash and never partially populate a snapshot.
    func testMalformedOrTruncatedJsonForThePersistedStateSnapshotFailsClosedViaTryDecode() {
        let validJson = try! JSONEncoder().encode(V2PersistedState.Snapshot.empty)
        let malformedPayloads: [(String, Data)] = [
            ("empty data", Data()),
            ("not json at all", Data("not json at all".utf8)),
            ("valid json, wrong shape", Data(#"{"foo":"bar"}"#.utf8)),
            ("truncated valid snapshot", validJson.dropLast(max(1, validJson.count / 2))),
        ]
        for (label, payload) in malformedPayloads {
            let decoded = try? JSONDecoder().decode(V2PersistedState.Snapshot.self, from: payload)
            XCTAssertNil(decoded, "\(label) must fail closed (nil), never decode into a usable snapshot")
        }
    }

    /// Fix E1's own new store: a truncated snapshot of in-flight pairing transactions must THROW on
    /// decode (a hard parse failure any real caller notices), not silently produce a store with
    /// garbage/partial `PendingTxn` entries — there is no `PendingTxn` field that can be legally
    /// missing (no manual `init(from:)` weakens the synthesized `Codable` requirement, see this type's
    /// own doc comment on `V2Processor.PendingTxn`).
    func testTruncatedJsonForThePendingTxnStoreSnapshotThrowsInsteadOfDecodingGarbage() {
        let ephemeral = V2Suite.generateX25519()
        let txn = V2Processor.PendingTxn(role: .initiator, phase: .confirming, chatId: "100", txnId: "t1", ownEphemeral: ephemeral, ownWire: "P2:INVITE")
        let store = V2Processor.InMemoryTxnStore()
        store.set("t1", txn)
        let validJson = try! JSONEncoder().encode(store.toSnapshot())
        let truncated = validJson.dropLast(max(1, validJson.count / 3))

        XCTAssertThrowsError(try JSONDecoder().decode(V2Processor.InMemoryTxnStore.Snapshot.self, from: truncated))
    }

    /// Fix E1's chat-slot CAS: a slot value of the wrong JSON type (a number where `TId == String` is
    /// expected) must throw on decode, not get silently coerced into some default/garbage `String`.
    func testMalformedJsonForTheChatSlotCasSnapshotThrowsOnATypeMismatch() {
        let malformed = Data(#"{"slots":{"100":12345}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(V2SelectionCas<String>.Snapshot.self, from: malformed))
    }

    /// A structurally-valid JSON object that is simply missing a required key (`entries`) must also
    /// throw, not decode to an empty/default store.
    func testJsonMissingARequiredKeyForThePendingTxnStoreSnapshotThrows() {
        let malformed = Data(#"{}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(V2Processor.InMemoryTxnStore.Snapshot.self, from: malformed))
    }

    // MARK: real on-disk corruption through V2KeychainStorage

    /// End-to-end version of the above through the actual production storage backend: persist a real
    /// snapshot, corrupt bytes directly on disk (simulating bit rot / a truncated write / tampering,
    /// never a valid re-encryption), then reload with a FRESH `V2KeychainStorage` instance. Guard:
    /// `V2KeychainStorage.load()`'s `guard ... let json = SealedBlob.open(blob, key: key) else { return
    /// nil }` — XChaCha20-Poly1305's AEAD authentication must reject the corrupted ciphertext outright,
    /// long before JSON decoding is even attempted. The higher-level property under test is that
    /// `V2PersistedState.load` then degrades to a completely FRESH empty state rather than crashing or
    /// resurrecting the pre-corruption binding from a stale in-memory copy.
    func testCorruptedOnDiskStateBlobFailsClosedInsteadOfCrashingOrResurrectingStaleData() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("v2persist-corrupt-\(UUID().uuidString)")
        let accountKey = "corrupt-\(UUID().uuidString)"
        let storage = V2KeychainStorage(accountKey: accountKey, basePath: tmpDir.path)
        defer { storage.wipe(); try? FileManager.default.removeItem(at: tmpDir) }

        let state = V2PersistedState.load(storage: storage)
        state.bindingStore.install(V2Binding.freshTemplate(
            chatId: "100", bindingId: "b1", epoch: 1, deviceRoster: ["d1"], deviceKeys: [:],
            revision: 1, txnId: "t1", installedAtMs: 1
        ))
        state.persist()

        let fileURL = tmpDir.appendingPathComponent("secutg", isDirectory: true).appendingPathComponent("v2-state.bin")
        guard var bytes = try? Data(contentsOf: fileURL), !bytes.isEmpty else {
            return XCTFail("expected a sealed blob to already exist on disk after persist()")
        }
        // Flip bytes in the middle of the sealed blob — corruption, not a valid re-encryption — so the
        // AEAD tag can no longer authenticate.
        let corruptStart = bytes.count / 2
        for offset in corruptStart..<min(bytes.count, corruptStart + 8) {
            bytes[offset] ^= 0xFF
        }
        try! bytes.write(to: fileURL)

        let reloadedStorage = V2KeychainStorage(accountKey: accountKey, basePath: tmpDir.path)
        XCTAssertNil(reloadedStorage.load(), "a corrupted on-disk blob must fail closed to nil, not decode into garbage")

        let reloaded = V2PersistedState.load(storage: reloadedStorage)
        XCTAssertNil(reloaded.bindingStore.current("100"), "corrupted state must start fresh, never resurrect the pre-corruption binding")
    }

    /// Same guard, a different corruption shape: a truncated (short-write) file — e.g. the process was
    /// killed mid-`write(to:)` — instead of bit-flipped bytes.
    func testTruncatedOnDiskStateBlobFailsClosedInsteadOfCrashing() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("v2persist-truncated-\(UUID().uuidString)")
        let accountKey = "truncated-\(UUID().uuidString)"
        let storage = V2KeychainStorage(accountKey: accountKey, basePath: tmpDir.path)
        defer { storage.wipe(); try? FileManager.default.removeItem(at: tmpDir) }

        let state = V2PersistedState.load(storage: storage)
        state.bindingStore.install(V2Binding.freshTemplate(
            chatId: "200", bindingId: "b2", epoch: 1, deviceRoster: ["d1"], deviceKeys: [:],
            revision: 1, txnId: "t2", installedAtMs: 1
        ))
        state.persist()

        let fileURL = tmpDir.appendingPathComponent("secutg", isDirectory: true).appendingPathComponent("v2-state.bin")
        guard let bytes = try? Data(contentsOf: fileURL), bytes.count > 4 else {
            return XCTFail("expected a sealed blob to already exist on disk after persist()")
        }
        try! bytes.prefix(bytes.count / 3).write(to: fileURL)

        let reloadedStorage = V2KeychainStorage(accountKey: accountKey, basePath: tmpDir.path)
        XCTAssertNil(reloadedStorage.load(), "a truncated on-disk blob must fail closed to nil, not crash")
        XCTAssertNil(V2PersistedState.load(storage: reloadedStorage).bindingStore.current("200"))
    }
}
