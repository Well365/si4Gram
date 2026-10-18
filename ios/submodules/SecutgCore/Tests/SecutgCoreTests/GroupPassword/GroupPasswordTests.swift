import XCTest
@testable import SecutgCore

/// PLAN.md 3.38 — mirrors Web `src/secutg/grouppw/grouppw.test.ts` case for case (except Web's `ops: 1.5`,
/// which Swift's `Int` cannot express).
final class GroupPasswordTests: XCTestCase {
    private let fastOps = 1
    private let fastMem = GroupPassword.memMin
    private let group = "-1001234567890"
    private let pw = "hunter22"

    private func key(_ v: UInt8) -> [UInt8] { return [UInt8](repeating: v, count: 32) }

    private func flip(_ bytes: [UInt8], _ at: Int) -> [UInt8] {
        var out = bytes
        out[at] ^= 0x01
        return out
    }

    private func wrapped(history: [[UInt8]] = [], current: UInt8 = 9) throws -> GroupPasswordLockedFields {
        return try GroupPassword.wrapGroupKeys(
            password: pw, groupId: group, current: key(current), history: history, ops: fastOps, mem: fastMem
        )
    }

    private func unwrap(_ f: GroupPasswordLockedFields, _ password: String? = nil, _ groupId: String? = nil) -> GroupPasswordUnwrapResult {
        return GroupPassword.unwrapGroupKeys(f, password: password ?? pw, groupId: groupId ?? group)
    }

    // MARK: deriveKek

    func testDefaultsAreInteractiveAsPlainNumbers() {
        XCTAssertEqual(GroupPassword.defaultOps, 2)
        XCTAssertEqual(GroupPassword.defaultMem, 67_108_864)
    }

    func testDeriveKekDeterministicSaltAndNfcSensitive() throws {
        let salt = [UInt8](repeating: 1, count: 16)
        let a = try GroupPassword.deriveKek(password: pw, salt: salt, ops: fastOps, mem: fastMem)
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(try GroupPassword.deriveKek(password: pw, salt: salt, ops: fastOps, mem: fastMem), a)
        XCTAssertNotEqual(try GroupPassword.deriveKek(password: pw, salt: flip(salt, 0), ops: fastOps, mem: fastMem), a)
        let nfd = try GroupPassword.deriveKek(password: "cafe\u{0301}!!", salt: salt, ops: fastOps, mem: fastMem)
        XCTAssertEqual(nfd, try GroupPassword.deriveKek(password: "caf\u{00e9}!!", salt: salt, ops: fastOps, mem: fastMem))
    }

    func testDeriveKekRefusesBadSaltAndOutOfRangeParams() {
        let salt = [UInt8](repeating: 0, count: 16)
        XCTAssertThrowsError(try GroupPassword.deriveKek(password: pw, salt: [UInt8](repeating: 0, count: 15), ops: fastOps, mem: fastMem))
        XCTAssertThrowsError(try GroupPassword.deriveKek(password: pw, salt: salt, ops: GroupPassword.opsMax + 1, mem: fastMem))
        XCTAssertThrowsError(try GroupPassword.deriveKek(password: pw, salt: salt, ops: 1, mem: GroupPassword.memMax + 1024))
        XCTAssertThrowsError(try GroupPassword.deriveKek(password: pw, salt: salt, ops: 1, mem: GroupPassword.memMin + 1))
    }

    // MARK: validatePassword

    func testValidatePasswordCountsCodePoints() {
        let cases: [(String, Bool)] = [
            ("abcde", false), ("abcdef", true),
            ("群密码测试", false), ("群密码测试一", true),
            ("🔐🔐🔐", false), // 6 UTF-16 units, 3 code points
            ("🔐🔐🔐🔐🔐", false), ("🔐🔐🔐🔐🔐🔐", true),
            ("𠀀𠀀𠀀𠀀𠀀", false), // CJK Ext-B, surrogate pairs in UTF-16
        ]
        for (text, ok) in cases {
            XCTAssertEqual(GroupPassword.validatePassword(text) == .ok, ok, text)
        }
    }

    func testValidatePasswordCountsAfterNfcAndRejectsLongInput() {
        XCTAssertEqual(GroupPassword.countCodePoints(String(repeating: "e\u{0301}", count: 3)), 3)
        XCTAssertEqual(GroupPassword.validatePassword(String(repeating: "x", count: 257)), .tooLong)
        XCTAssertEqual(GroupPassword.validatePassword("abc"), .tooShort)
        XCTAssertEqual(PasswordCheck.tooShort.rawValue, "too_short")
        XCTAssertEqual(PasswordCheck.tooLong.rawValue, "too_long")
    }

    func testWrapRefusesShortPassword() {
        XCTAssertThrowsError(try GroupPassword.wrapGroupKeys(
            password: "12345", groupId: group, current: key(1), ops: fastOps, mem: fastMem
        )) { error in
            XCTAssertEqual(error as? GroupPassword.Failure, .passwordRejected(.tooShort))
        }
    }

    // MARK: wrap / unwrap

    func testRoundTripWithHistoryRandomSaltAndNonces() throws {
        let f = try wrapped(history: [key(1), key(2)])
        XCTAssertEqual(unwrap(f), .ok(current: key(9), history: [key(1), key(2)]))
        let g = try wrapped(history: [key(1), key(2)])
        XCTAssertNotEqual(g.salt, f.salt)
        XCTAssertNotEqual(Array(g.wrap[0..<24]), Array(f.wrap[0..<24]))
    }

    func testWrongPasswordAndWrongGroupAreWrongPassword() throws {
        let f = try wrapped(history: [key(1), key(2)])
        XCTAssertEqual(unwrap(f, "hunter23"), .failure(.wrongPassword))
        XCTAssertEqual(unwrap(f, nil, "-1001234567891"), .failure(.wrongPassword))
    }

    func testTamperedWrapSaltParamsCannotOpen() throws {
        let f = try wrapped(history: [key(1), key(2)])
        let bad = [
            f.with(wrap: flip(f.wrap, 40)),
            f.with(wrap: flip(f.wrap, 3)), // nonce
            f.with(salt: flip(f.salt, 0)),
            f.with(ops: 2),
            f.with(mem: GroupPassword.memMin * 2),
        ]
        for b in bad { XCTAssertEqual(unwrap(b), .failure(.wrongPassword)) }
    }

    func testHistoryEntriesCannotBeSwapped() throws {
        let f = try wrapped(history: [key(1), key(2)])
        XCTAssertEqual(unwrap(f.with(hist: [f.hist[1], f.hist[0]])), .failure(.malformed))
        XCTAssertEqual(unwrap(f.with(wrap: f.hist[0], hist: [f.wrap, f.hist[1]])), .failure(.wrongPassword))
        XCTAssertEqual(unwrap(f.with(hist: [flip(f.hist[0], 50), f.hist[1]])), .failure(.malformed))
    }

    func testHistoryDedupedAndCappedToNewest16() throws {
        let history = [key(9), key(1), key(1)] + (0..<20).map { key(UInt8(20 + $0)) }
        let f = try wrapped(history: history)
        XCTAssertEqual(f.hist.count, GroupPassword.historyMax)
        XCTAssertEqual(unwrap(f), .ok(current: key(9), history: (0..<16).map { key(UInt8(24 + $0)) }))
    }

    func testGuardsUnsupportedKdfParamsAndMalformed() throws {
        let f = try wrapped(history: [key(1), key(2)])
        XCTAssertEqual(unwrap(f.with(kdf: "scrypt")), .failure(.unsupportedKdf))
        XCTAssertEqual(unwrap(f.with(version: 2)), .failure(.unsupportedKdf))
        let outOfRange = [
            f.with(ops: 0), f.with(ops: GroupPassword.opsMax + 1), f.with(mem: GroupPassword.memMax * 4),
            f.with(mem: 1024), f.with(mem: GroupPassword.memMin + 1),
        ]
        for b in outOfRange { XCTAssertEqual(unwrap(b), .failure(.paramsOutOfRange)) }
        let malformed = [
            f.with(salt: Array(f.salt[0..<15])),
            f.with(wrap: Array(f.wrap[0..<71])),
            f.with(hist: [Array(f.hist[0][1...])]),
            f.with(hist: [[UInt8]](repeating: f.hist[0], count: 17)),
        ]
        for b in malformed { XCTAssertEqual(unwrap(b), .failure(.malformed)) }
        XCTAssertEqual(unwrap(f, nil, ""), .failure(.malformed))
        XCTAssertEqual(GroupPasswordUnwrapFailure.wrongPassword.rawValue, "wrong_password")
        XCTAssertEqual(GroupPasswordUnwrapFailure.malformed.rawValue, "malformed")
        XCTAssertEqual(GroupPasswordUnwrapFailure.unsupportedKdf.rawValue, "unsupported_kdf")
        XCTAssertEqual(GroupPasswordUnwrapFailure.paramsOutOfRange.rawValue, "params_out_of_range")
    }

    // MARK: key payload, locked variant

    func testOldFormatPayloadsParseExactlyAsBefore() {
        let adminPk = key(0x42)
        let old = KeyPayload.build(masterKey: key(7), adminPk: adminPk, mode: .auto)
        let expected = KeyPayload(masterKey: key(7), adminPk: adminPk, mode: .auto)
        XCTAssertEqual(KeyPayload.parse(old), expected)
        XCTAssertEqual(KeyPayload.parse(KeyPayload.build(masterKey: key(7), adminPk: nil)),
                       KeyPayload(masterKey: key(7), adminPk: nil, mode: .manual))
        XCTAssertEqual(KeyPayload.parse(old, allowLocked: true), .plain(expected))
        XCTAssertEqual(KeyPayload.parse(old, allowLocked: false), .plain(expected))
    }

    func testLockedPayloadInvisibleToLegacyParserAndLockedWithOptIn() throws {
        let adminPk = key(0x42)
        let f = try wrapped(history: [key(1)])
        let text = KeyPayload.buildLocked(f, adminPk: adminPk, mode: .auto)
        XCTAssertTrue(text.hasPrefix("secutg://key?pw=1&kdf=argon2id13&ops=1&mem=8388608&salt="), text)
        XCTAssertTrue(text.contains("&hist="))
        XCTAssertTrue(text.contains("&admin_pk=\(Base64Url.encode(adminPk))&mode=auto"))
        XCTAssertNil(KeyPayload.parse(text))
        XCTAssertNil(KeyPayload.parse(text, allowLocked: false))
        let parsed = KeyPayload.parse(text, allowLocked: true)
        XCTAssertEqual(parsed, .locked(LockedKeyPayload(fields: f, adminPk: adminPk, mode: .auto)))
        guard case .locked(let locked)? = parsed else { return XCTFail("expected locked") }
        XCTAssertEqual(unwrap(locked.fields), .ok(current: key(9), history: [key(1)]))
    }

    func testNoHistoryNoHistFieldAndMissingAdminModeLikeOldForm() throws {
        let f = try wrapped()
        let text = KeyPayload.buildLocked(f, adminPk: nil)
        XCTAssertFalse(text.contains("hist="))
        guard case .locked(let locked)? = KeyPayload.parse(text, allowLocked: true) else { return XCTFail("expected locked") }
        XCTAssertEqual(locked.mode, .manual)
        XCTAssertNil(locked.adminPk)
    }

    func testStrictHeadRejectsMalformedVariants() throws {
        let f = try wrapped(history: [key(1)])
        let good = KeyPayload.buildLocked(f, adminPk: nil)
        let histValue = Base64Url.encode(f.hist[0])
        let bad = [
            good.replacingOccurrences(of: "pw=1", with: "pw=2"),
            good.replacingOccurrences(of: "ops=1", with: "ops=01"),
            good.replacingOccurrences(of: "ops=1", with: "ops=-1"),
            good.replacingOccurrences(of: "ops=1&mem=8388608", with: "mem=8388608&ops=1"),
            good.replacingOccurrences(of: "&kdf=argon2id13", with: ""),
            good.replacingOccurrences(of: "kdf=argon2id13", with: "kdf=Argon2"),
            good + "&extra=1",
            good.replacingOccurrences(of: "salt=", with: "salt=*"),
            good.replacingOccurrences(of: "hist=\(histValue)", with: "hist="),
            good.replacingOccurrences(of: "hist=\(histValue)",
                                      with: "hist=" + [String](repeating: histValue, count: 17).joined(separator: ",")),
            "secutg://key?pw=1",
        ]
        for text in bad {
            XCTAssertNotEqual(text, good)
            XCTAssertNil(KeyPayload.parse(text, allowLocked: true), text)
        }
    }
}
