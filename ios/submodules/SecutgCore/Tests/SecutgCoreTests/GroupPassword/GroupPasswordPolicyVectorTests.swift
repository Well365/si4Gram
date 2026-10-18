import XCTest
@testable import SecutgCore

/// PLAN.md 3.38.2 shared `GP1` vectors — `Vectors/vectors-grouppw-policy.json` is a byte-for-byte copy of Web
/// `src/secutg/grouppw/vectors-grouppw-policy.json`. Mirrors Web `grouppw/policyVectors.test.ts`: every case is
/// re-derived through the production functions and must match exactly.
final class GroupPasswordPolicyVectorTests: XCTestCase {
    private static let expectedCaseCount = 37

    private var file: [String: Any] { return Vectors.load("vectors-grouppw-policy") }
    private var cases: [[String: Any]] { return file["cases"] as? [[String: Any]] ?? [] }

    func testFileShapeAndThePlanVectorIsInItVerbatim() throws {
        XCTAssertEqual(file["format"] as? String, "secutg-grouppw-policy-vectors/1")
        XCTAssertEqual(cases.count, Self.expectedCaseCount)
        let plan = try XCTUnwrap(cases.first { $0["name"] as? String == "plan-3.38.2-vector" })
        XCTAssertEqual(plan["password"] as? String, "correct horse")
        XCTAssertEqual(plan["group_id"] as? String, "-1001234567890")
        XCTAssertEqual(plan["salt_hex"] as? String, "000102030405060708090a0b0c0d0e0f")
        let expect = try XCTUnwrap(plan["expect"] as? [String: Any])
        XCTAssertEqual(expect["kek_hex"] as? String, "9aab5a81db651bf866ff7b6169794d2ad9bb00f3d95177925a5fca692a34dbd1")
        XCTAssertEqual(expect["verifier_hex"] as? String, "514e5ba3bde3f3ce38806874db3e163601d68de3efa491578de1f3800c3916b4")
    }

    func testAllCases() throws {
        var results: [String] = []
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let kind = c["kind"] as? String ?? "?"
            let before = testRun?.failureCount ?? 0
            try XCTContext.runActivity(named: "\(kind): \(name)") { _ in
                switch kind {
                case "policy_on": try runOn(c)
                case "policy_off": try runOff(c)
                case "unlock": try runUnlock(c)
                case "payload_parse_fail":
                    XCTAssertNil(GroupPassword.parsePolicyPayload(c["payload"] as? String ?? "x"), name)
                case "wire_parse_fail":
                    let wire = c["wire"] as? String ?? ""
                    XCTAssertNil(GP1.parse(wire), name)
                    XCTAssertFalse(GP1.isGP1(wire) && GP1.parse(wire) != nil, name)
                default: XCTFail("unknown case kind \(kind)")
                }
            }
            let ok = (testRun?.failureCount ?? 0) == before
            results.append("grouppw-policy vector [\(ok ? "PASS" : "FAIL")] \(kind): \(name)")
        }
        print(results.joined(separator: "\n"))
        XCTAssertEqual(results.count, Self.expectedCaseCount)
    }

    private func int(_ c: [String: Any], _ key: String) -> Int {
        return (c[key] as? NSNumber)?.intValue ?? -1
    }

    private func runOn(_ c: [String: Any]) throws {
        let expect = try XCTUnwrap(c["expect"] as? [String: Any])
        let password = try XCTUnwrap(c["password"] as? String)
        let groupId = try XCTUnwrap(c["group_id"] as? String)
        let salt = Vectors.hex(try XCTUnwrap(c["salt_hex"] as? String))
        let ops = int(c, "ops"), mem = int(c, "mem")
        let at = Int64(int(c, "at"))
        let publisher = try XCTUnwrap(c["publisher_id"] as? String)

        let kek = try GroupPassword.deriveKek(password: password, salt: salt, ops: ops, mem: mem)
        XCTAssertEqual(Hex.encode(kek[...]), expect["kek_hex"] as? String)
        let verifier = try GroupPassword.computeVerifier(kek: kek, groupId: groupId)
        XCTAssertEqual(Hex.encode(verifier[...]), expect["verifier_hex"] as? String)
        let params = try GroupPassword.makePolicyParams(password: password, groupId: groupId, ops: ops, mem: mem, salt: salt)
        XCTAssertEqual(params.verifier, verifier)

        XCTAssertEqual(GroupPassword.buildPolicyPayload(.on(params)), expect["payload"] as? String)
        let wire = GP1.build(chatId: groupId, at: at, payload: .on(params), publisherId: publisher,
                             obfuscationNonce: Vectors.hex(try XCTUnwrap(c["obfuscation_nonce_hex"] as? String)))
        XCTAssertEqual(wire, expect["wire"] as? String)
        let expectedWire = try XCTUnwrap(expect["wire"] as? String)
        XCTAssertEqual(GP1.parse(expectedWire), GP1.Parsed(chatId: groupId, at: at, payload: .on(params), publisherId: publisher))
        XCTAssertTrue(Rekey.isControlMessage(expectedWire))
    }

    private func runOff(_ c: [String: Any]) throws {
        let expect = try XCTUnwrap(c["expect"] as? [String: Any])
        let groupId = try XCTUnwrap(c["group_id"] as? String)
        let at = Int64(int(c, "at"))
        let publisher = try XCTUnwrap(c["publisher_id"] as? String)
        XCTAssertEqual(GroupPassword.buildPolicyPayload(.off), expect["payload"] as? String)
        let wire = GP1.build(chatId: groupId, at: at, payload: .off, publisherId: publisher,
                             obfuscationNonce: Vectors.hex(try XCTUnwrap(c["obfuscation_nonce_hex"] as? String)))
        XCTAssertEqual(wire, expect["wire"] as? String)
        XCTAssertEqual(GP1.parse(try XCTUnwrap(expect["wire"] as? String)),
                       GP1.Parsed(chatId: groupId, at: at, payload: .off, publisherId: publisher))
    }

    private func runUnlock(_ c: [String: Any]) throws {
        let policy = try XCTUnwrap(c["policy"] as? [String: Any])
        let params = GroupPasswordPolicyParams(
            kdf: GroupPassword.kdfArgon2id13, ops: int(policy, "ops"), mem: int(policy, "mem"),
            salt: Vectors.hex(try XCTUnwrap(policy["salt_hex"] as? String)),
            verifier: Vectors.hex(try XCTUnwrap(policy["verifier_hex"] as? String)))
        let failure = GroupPassword.verifyPolicy(params, password: try XCTUnwrap(c["password"] as? String),
                                                 groupId: try XCTUnwrap(policy["group_id"] as? String))
        XCTAssertEqual(failure == nil, c["expect_match"] as? Bool)
        if failure != nil { XCTAssertEqual(failure, .wrongPassword) }
    }
}
