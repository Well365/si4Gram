import XCTest
@testable import SecutgCore

/// PLAN.md 3.38 shared vectors — `Vectors/vectors-grouppw.json` is a byte-for-byte copy of Web
/// `src/secutg/grouppw/vectors-grouppw.json`. Mirrors Web `grouppw/vectors.test.ts`: every case is re-derived from
/// its inputs and every `expect` field must match exactly.
final class GroupPasswordVectorTests: XCTestCase {
    private static let expectedCaseCount = 17

    private var file: [String: Any] { return Vectors.load("vectors-grouppw") }
    private var cases: [[String: Any]] { return file["cases"] as? [[String: Any]] ?? [] }

    func testFileShape() {
        XCTAssertEqual(file["format"] as? String, "secutg-grouppw-vectors/1")
        XCTAssertEqual(cases.count, Self.expectedCaseCount)
    }

    func testAllCases() throws {
        var results: [String] = []
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let kind = c["kind"] as? String ?? "?"
            let before = testRun?.failureCount ?? 0
            try XCTContext.runActivity(named: "\(kind): \(name)") { _ in
                switch kind {
                case "wrap": try runWrap(c)
                case "unwrap_fail": runUnwrapFail(c)
                case "parse_fail": runParseFail(c)
                case "plain": runPlain(c)
                default: XCTFail("unknown case kind \(kind)")
                }
            }
            let ok = (testRun?.failureCount ?? 0) == before
            results.append("grouppw vector [\(ok ? "PASS" : "FAIL")] \(kind): \(name)")
        }
        print(results.joined(separator: "\n"))
        XCTAssertEqual(results.count, Self.expectedCaseCount)
    }

    private func runWrap(_ c: [String: Any]) throws {
        let name = c["name"] as? String ?? "?"
        let password = try XCTUnwrap(c["password"] as? String)
        let groupId = try XCTUnwrap(c["group_id"] as? String)
        let ops = try XCTUnwrap(c["ops"] as? Int)
        let mem = try XCTUnwrap(c["mem"] as? Int)
        let salt = Vectors.hex(try XCTUnwrap(c["salt_hex"] as? String))
        let nonces = (c["nonces_hex"] as? [String] ?? []).map(Vectors.hex)
        let current = Vectors.hex(try XCTUnwrap(c["current_hex"] as? String))
        let history = (c["history_input_hex"] as? [String] ?? []).map(Vectors.hex)
        let adminPk = (c["admin_pk_b64url"] as? String).map(Vectors.b64)
        let mode = (c["mode"] as? String).flatMap(Rekey.KeyMode.init(rawValue:))
        let expect = try XCTUnwrap(c["expect"] as? [String: Any])
        let expectHistory = (expect["history_hex"] as? [String] ?? []).map(Vectors.hex)

        let kek = try GroupPassword.deriveKek(password: password, salt: salt, ops: ops, mem: mem)
        XCTAssertEqual(Hex.encode(kek[...]), expect["kek_hex"] as? String, name)
        XCTAssertEqual(GroupPassword.normaliseHistory(current: current, history: history), expectHistory, name)

        let fields = try GroupPassword.wrapGroupKeys(
            password: password, groupId: groupId, current: current, history: history,
            ops: ops, mem: mem, salt: salt, nonces: nonces
        )
        XCTAssertEqual(Base64Url.encode(fields.wrap), expect["wrap_b64url"] as? String, name)
        XCTAssertEqual(fields.hist.map(Base64Url.encode), expect["hist_b64url"] as? [String], name)
        let payload = try XCTUnwrap(expect["payload"] as? String)
        XCTAssertEqual(KeyPayload.buildLocked(fields, adminPk: adminPk, mode: mode), payload, name)

        XCTAssertNil(KeyPayload.parse(payload), name)
        guard case .locked(let locked)? = KeyPayload.parse(payload, allowLocked: true) else {
            return XCTFail("\(name): payload did not parse as locked")
        }
        XCTAssertEqual(locked.fields, fields, name)
        XCTAssertEqual(locked.adminPk, adminPk, name)
        XCTAssertEqual(locked.mode, mode ?? .manual, name)
        XCTAssertEqual(
            GroupPassword.unwrapGroupKeys(locked.fields, password: password, groupId: groupId),
            .ok(current: current, history: expectHistory), name
        )
    }

    private func runUnwrapFail(_ c: [String: Any]) {
        let name = c["name"] as? String ?? "?"
        let payload = c["payload"] as? String ?? ""
        XCTAssertNil(KeyPayload.parse(payload), name)
        guard case .locked(let locked)? = KeyPayload.parse(payload, allowLocked: true) else {
            return XCTFail("\(name): payload did not parse as locked")
        }
        let result = GroupPassword.unwrapGroupKeys(
            locked.fields, password: c["password"] as? String ?? "", groupId: c["group_id"] as? String ?? ""
        )
        guard case .failure(let reason) = result else { return XCTFail("\(name): unexpectedly unwrapped") }
        XCTAssertEqual(reason.rawValue, c["expect_error"] as? String, name)
    }

    private func runParseFail(_ c: [String: Any]) {
        let name = c["name"] as? String ?? "?"
        let payload = c["payload"] as? String ?? ""
        XCTAssertFalse(payload.isEmpty, name)
        XCTAssertNil(KeyPayload.parse(payload, allowLocked: true), name)
        XCTAssertNil(KeyPayload.parse(payload), name)
    }

    private func runPlain(_ c: [String: Any]) {
        let name = c["name"] as? String ?? "?"
        let payload = c["payload"] as? String ?? ""
        let expected = KeyPayload(
            masterKey: Vectors.hex(c["master_hex"] as? String ?? ""),
            adminPk: (c["admin_pk_b64url"] as? String).map(Vectors.b64),
            mode: Rekey.KeyMode(rawValue: c["mode"] as? String ?? "") ?? .manual
        )
        XCTAssertEqual(KeyPayload.parse(payload, allowLocked: true), .plain(expected), name)
        XCTAssertEqual(KeyPayload.parse(payload), expected, name)
    }
}
