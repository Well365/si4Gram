import Foundation
@testable import SecutgCore

/// The keyring every suite builds from the shared inputs.
///
/// It is **decoded from `inputs.maximalSnapshot`** rather than assembled in code, and that is the point:
/// five clients each building "the same" ring from five constructors is five chances to build five
/// slightly different rings, and then a mismatch downstream says nothing about the protocol. Reading one
/// hand-written wire snapshot through each client's own decoder makes the starting state provably
/// identical — and makes the decoder itself the first thing under test.
enum XCheckFixtures {
    /// The maximal ring: every table populated, nothing at a default value.
    static func rich(_ env: XCheckEnv) throws -> KeyRing.Snapshot {
        var s = TransferSnapshotCodec.decode(try env.section("maximalSnapshot"))
        // Local-only by ruling (PLAN.md 3.19 / 3.16 / 3.0), set to non-defaults precisely so a vector
        // that leaks them into the K1 wire is impossible to miss.
        s.localCiphertext = false
        s.wipeNeedsConfirmation = false
        s.wipeCustomPhrase = "never leaves this device"
        s.wipeListensToPhrase = false
        s.wipeResetsAuthorizations = false
        return s
    }

    /// A ring seeded with `snapshot`, with a clock frozen at the shared "now".
    static func ring(_ env: XCheckEnv, _ snapshot: KeyRing.Snapshot) throws -> KeyRing {
        let now = try env.nowMs()
        return KeyRing(storage: MemoryKeyRingStorage(snapshot), clock: { now },
                       epochDays: try env.epochDays(), epochTolerance: try env.epochTolerance())
    }

    /// The shared chat key of a named chat in `inputs.chats`.
    static func chatKey(_ env: XCheckEnv, _ name: String) throws -> String {
        for chat in try env.list("chats") where (chat["name"] as? String) == name {
            return try chat.string("key")
        }
        throw XCheckError.message("no chat named \(name) in inputs.json")
    }
}
