import XCTest
@testable import SecutgCore

/// PLAN.md 3.35 cross-client vector — the ONE thing about `G2` five clients can disagree on.
///
/// **There is no byte-for-byte build vector for `G2`, and there cannot be.** The obfuscation layer takes a
/// fresh nonce every time (3.35.8), so the same key produces a different wire on every call — unlike `N1`,
/// whose whole wire is pinned in `inputs.json`. What five clients have to agree on is the other direction:
/// given one wire, they must all recover the same payload, `at` and publisher.
///
/// That direction is where the risk lives. An iOS admin's broadcast has to open on an Android member's
/// phone, and everything between them is shared-constant machinery: the passphrase, the generichash to 32
/// bytes, XChaCha20-Poly1305, base64url without padding. A port that hashes the passphrase differently, or
/// pads its base64, produces a `G2` the other four read as malformed — and a malformed `G2` is
/// indistinguishable from "not ours" by design, so nobody would see an error worth chasing.
///
/// The wire below was produced by the Web client and is pasted verbatim into the same test on all five.
/// Regenerate it only when the format changes, and change all five together.
final class G2VectorTests: XCTestCase {
    private let wire = "G2:-1001:1789300000:S1u55IVwkNDM418KvS6fihE-S5zNSYnaVxvSQ_V2ZYxvAC8EqaQKUu2yWDz2nmQ47o0qKAF1XX323PoMzUbM2zyhnhF3bSkoLUOBOPO-Z7uyIL8Y7CFTE4uCe6vLFYotvz3z-V0WzBJMMw4h-IUO0Fe7KJLypvVlDulM3gasm6D9wOuKT3a93Hboa6yfx7t7DbhimZMevsSGugRmpJyz:7001"
    private let payload = "secutg://key?BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc&admin_pk=CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk&mode=auto"

    func testThisClientCanReadTheSharedWire() throws {
        let parsed = try XCTUnwrap(G2.parse(wire), "this build cannot unwrap the shared vector")
        XCTAssertEqual(parsed.chatId, "-1001")
        XCTAssertEqual(parsed.at, 1789300000)
        XCTAssertEqual(parsed.publisherId, "7001")
        XCTAssertEqual(parsed.keyPayload, payload)
    }
}
