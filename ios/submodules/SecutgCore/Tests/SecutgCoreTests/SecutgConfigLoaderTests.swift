import XCTest
@testable import SecutgCore

final class SecutgConfigLoaderTests: XCTestCase {
    let builtIn = """
    {"api_id": 12345, "api_hash": "0123456789abcdef0123456789abcdef", "app_name": "secuTG",
     "crypto": {"epoch_days": 1, "epoch_tolerance": 1, "rekey_reminder_days": 7, "max_plaintext_chars": 3000}}
    """.data(using: .utf8)!

    func testBuiltInAlone() throws {
        let c = try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: builtIn)
        XCTAssertEqual(c.apiId, 12345)
        XCTAssertEqual(c.appName, "secuTG")
        XCTAssertEqual(c.crypto, CryptoConfig.defaults)
    }

    /// macOS dev builds ship no bundled secutg.json; a complete user file alone must be enough.
    func testUserFileAloneWithoutBuiltIn() throws {
        let user = #"{"api_id": 777, "api_hash": "0123456789abcdef0123456789abcdef", "app_name": "secuTG", "crypto": {"epoch_days": 1, "epoch_tolerance": 1, "rekey_reminder_days": 7, "max_plaintext_chars": 3000}}"#.data(using: .utf8)!
        let c = try SecutgConfigLoader.resolve(userFileJSON: user, builtInJSON: nil)
        XCTAssertEqual(c.apiId, 777)
        XCTAssertEqual(c.crypto.maxPlaintextChars, 3000)
    }

    func testUserFileAndOverridesWin() throws {
        let user = #"{"api_id": 999, "crypto": {"epoch_days": 7}}"#.data(using: .utf8)!
        let c = try SecutgConfigLoader.resolve(overrides: ["crypto.epoch_tolerance": "3"], userFileJSON: user, builtInJSON: builtIn)
        XCTAssertEqual(c.apiId, 999)
        XCTAssertEqual(c.crypto.epochDays, 7)
        XCTAssertEqual(c.crypto.epochTolerance, 3)
        XCTAssertEqual(c.crypto.rekeyReminderDays, 7)
    }

    /// PLAN.md 3.15: the sponsor block follows the same rule as distribution — built-in only, so a repackaged build
    /// cannot swap in its own payment codes. An absent or empty block hides the sponsor entry everywhere.
    func testSponsorIsReadFromTheBuiltInFileOnly() throws {
        let base = #""api_id": 1, "api_hash": "0123456789abcdef0123456789abcdef", "app_name": "secuTG", "crypto": {"epoch_days": 1, "epoch_tolerance": 1, "rekey_reminder_days": 7, "max_plaintext_chars": 3000}"#
        let bundled = "{\(base), \"sponsor\": {\"note\": \"thanks\", \"qrs\": [{\"label\": \"BTC\", \"value\": \"bitcoin:xyz\"}], \"links\": [{\"label\": \"Open Collective\", \"url\": \"https://example.org\"}], \"addresses\": [{\"label\": \"XMR\", \"value\": \"4abc\"}]}}".data(using: .utf8)!
        let user = "{\"api_id\": 222, \"sponsor\": {\"note\": \"send me money instead\", \"addresses\": [{\"label\": \"evil\", \"value\": \"1evil\"}]}}".data(using: .utf8)!
        let c = try SecutgConfigLoader.resolve(overrides: ["sponsor.note": "evil"], userFileJSON: user, builtInJSON: bundled)
        XCTAssertEqual(c.sponsor?.note, "thanks")
        XCTAssertEqual(c.sponsor?.qrs, [SponsorEntry(label: "BTC", value: "bitcoin:xyz")])
        XCTAssertEqual(c.sponsor?.links, [SponsorLink(label: "Open Collective", url: "https://example.org")])
        XCTAssertEqual(c.sponsor?.addresses, [SponsorEntry(label: "XMR", value: "4abc")])
        XCTAssertTrue(c.hasSponsorContent)

        // A user file alone contributes nothing, and a build without the block hides the entry
        XCTAssertNil(try SecutgConfigLoader.resolve(userFileJSON: "{\(base), \"sponsor\": {\"note\": \"evil\"}}".data(using: .utf8), builtInJSON: nil).sponsor)
        XCTAssertFalse(try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: "{\(base)}".data(using: .utf8)).hasSponsorContent)

        // The shipped-empty shape: present but with nothing in it
        let empty = try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: "{\(base), \"sponsor\": {\"note\": \"\", \"qrs\": [], \"links\": [], \"addresses\": []}}".data(using: .utf8))
        XCTAssertEqual(empty.sponsor, SponsorConfig.empty)
        XCTAssertFalse(empty.hasSponsorContent)

        // Malformed entries fail fast rather than showing a half-drawn page
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: "{\(base), \"sponsor\": {\"qrs\": [{\"label\": \"BTC\"}]}}".data(using: .utf8)))
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: "{\(base), \"sponsor\": {\"links\": \"nope\"}}".data(using: .utf8)))
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: "{\(base), \"sponsor\": {\"addresses\": [{\"label\": \"\", \"value\": \"x\"}]}}".data(using: .utf8)))
    }

    /// PLAN.md 3.11: distribution comes from the built-in file only; env and the user file cannot dress up a build.
    func testDistributionComesFromTheBuiltInFileOnly() throws {
        let bundled = #"{"api_id": 1, "api_hash": "0123456789abcdef0123456789abcdef", "app_name": "secuTG", "crypto": {"epoch_days": 1, "epoch_tolerance": 1, "rekey_reminder_days": 7, "max_plaintext_chars": 3000}, "distribution": {"version": "1.2.3", "channel": "official", "build": "abc · 2026-09-12"}}"#.data(using: .utf8)!
        let user = #"{"api_id": 222, "distribution": {"version": "9.9.9", "channel": "fake", "site": "https://evil.example"}}"#.data(using: .utf8)!
        let c = try SecutgConfigLoader.resolve(overrides: ["distribution.channel": "fake", "api_id": "333"], userFileJSON: user, builtInJSON: bundled)
        XCTAssertEqual(c.apiId, 333)
        XCTAssertEqual(c.distribution, DistributionConfig(version: "1.2.3", channel: "official", build: "abc · 2026-09-12"))
        XCTAssertNil(c.distribution?.site)

        let without = try SecutgConfigLoader.resolve(userFileJSON: user, builtInJSON: builtIn)
        XCTAssertNil(without.distribution)
        let userAlone = #"{"api_id": 777, "api_hash": "0123456789abcdef0123456789abcdef", "app_name": "secuTG", "crypto": {"epoch_days": 1, "epoch_tolerance": 1, "rekey_reminder_days": 7, "max_plaintext_chars": 3000}, "distribution": {"version": "9.9.9", "channel": "fake"}}"#.data(using: .utf8)!
        XCTAssertNil(try SecutgConfigLoader.resolve(userFileJSON: userAlone, builtInJSON: nil).distribution)
    }

    /// PLAN.md 3.48.8: `distribution.relay_source` follows the same built-in-only rule as the rest of the block —
    /// a user file cannot swap in a different relay repository link.
    func testRelaySourceComesFromTheBuiltInFileOnly() throws {
        let bundled = #"{"api_id": 1, "api_hash": "0123456789abcdef0123456789abcdef", "app_name": "secuTG", "crypto": {"epoch_days": 1, "epoch_tolerance": 1, "rekey_reminder_days": 7, "max_plaintext_chars": 3000}, "distribution": {"relay_source": "https://github.com/example/secuTG-relay"}}"#.data(using: .utf8)!
        let user = #"{"api_id": 222, "distribution": {"relay_source": "https://evil.example/relay"}}"#.data(using: .utf8)!
        let c = try SecutgConfigLoader.resolve(userFileJSON: user, builtInJSON: bundled)
        XCTAssertEqual(c.distribution?.relaySource, "https://github.com/example/secuTG-relay")

        let unset = try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: builtIn)
        XCTAssertNil(unset.distribution)

        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: #"{"api_id": 1, "api_hash": "0123456789abcdef0123456789abcdef", "app_name": "x", "crypto": {"epoch_days": 1, "epoch_tolerance": 1, "rekey_reminder_days": 7, "max_plaintext_chars": 3000}, "distribution": {"version": 1}}"#.data(using: .utf8)))
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: #"{"api_id": 1, "api_hash": "0123456789abcdef0123456789abcdef", "app_name": "x", "crypto": {"epoch_days": 1, "epoch_tolerance": 1, "rekey_reminder_days": 7, "max_plaintext_chars": 3000}, "distribution": []}"#.data(using: .utf8)))
    }

    func testFailsFastWithClearMessages() {
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: nil)) { XCTAssertEqual($0 as? SecutgConfigError, .invalidFile("no secutg.json found (neither bundled nor user file)")) }
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: #"{"api_id": 1}"#.data(using: .utf8))) { error in
            guard case SecutgConfigError.missingField(let m)? = error as? SecutgConfigError else { return XCTFail("\(error)") }
            // app_name and crypto.* fall back to the built-in defaults (as Web / Android); only the pair is required
            XCTAssertTrue(m.contains("api_hash") && !m.contains("crypto.epoch_days") && !m.contains("app_name"))
        }
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: #"{"api_hash": "short"}"#.data(using: .utf8), builtInJSON: builtIn)) {
            XCTAssertEqual($0 as? SecutgConfigError, .invalidField("`api_hash` must be a 32-character hex string"))
        }
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: #"{"api_id": "12"}"#.data(using: .utf8), builtInJSON: builtIn))
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: #"{"api_id": true}"#.data(using: .utf8), builtInJSON: builtIn))
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(overrides: ["api_id": "x"], userFileJSON: nil, builtInJSON: builtIn))
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: #"{"crypto": {"epoch_tolerance": -1}}"#.data(using: .utf8), builtInJSON: builtIn))
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: "[]".data(using: .utf8), builtInJSON: builtIn))
    }

    /// PLAN.md 3.21: no key means no watermark, and a malformed one is refused at startup rather than producing a
    /// pattern that traces to nothing. Unlike `distribution` / `sponsor` this is not a provenance claim, so it
    /// follows the ordinary layering: overrides > user file > bundled.
    func testWatermarkKeyAndAmplitude() throws {
        XCTAssertNil(try SecutgConfigLoader.resolve(userFileJSON: nil, builtInJSON: builtIn).watermark)

        let key = String(repeating: "AB", count: 32)
        let user = "{\"watermark_key\": \"\(key)\"}".data(using: .utf8)!
        let defaulted = try SecutgConfigLoader.resolve(userFileJSON: user, builtInJSON: builtIn)
        XCTAssertEqual(defaulted.watermark?.projectKey, [UInt8](repeating: 0xAB, count: 32))
        XCTAssertEqual(defaulted.watermark?.amplitude, WatermarkCarrier.amplitude)

        let tuned = try SecutgConfigLoader.resolve(overrides: ["watermark_amplitude": "2.5"], userFileJSON: user, builtInJSON: builtIn)
        XCTAssertEqual(tuned.watermark?.amplitude, 2.5)
        XCTAssertEqual(try SecutgConfigLoader.resolve(userFileJSON: "{\"watermark_key\": \"\(key)\", \"watermark_amplitude\": 0.5}".data(using: .utf8), builtInJSON: builtIn).watermark?.amplitude, 0.5)
        XCTAssertEqual(try SecutgConfigLoader.resolve(userFileJSON: "{\"watermark_key\": \"\(key)\", \"watermark_amplitude\": 4}".data(using: .utf8), builtInJSON: builtIn).watermark?.amplitude, 4)

        // An empty key is "not configured"; anything else malformed is an error, never a silent fallback.
        XCTAssertNil(try SecutgConfigLoader.resolve(userFileJSON: #"{"watermark_key": ""}"#.data(using: .utf8), builtInJSON: builtIn).watermark)
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: #"{"watermark_key": "abc"}"#.data(using: .utf8), builtInJSON: builtIn)) {
            XCTAssertEqual($0 as? SecutgConfigError, .invalidField("`watermark_key` must be 64 hex characters (32 bytes)"))
        }
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: "{\"watermark_key\": \"\(String(repeating: "zz", count: 32))\"}".data(using: .utf8), builtInJSON: builtIn))
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: #"{"watermark_key": 1}"#.data(using: .utf8), builtInJSON: builtIn))
        // Out of range is refused rather than clamped: the amplitude is the one thing the user can only judge on a screen.
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: "{\"watermark_key\": \"\(key)\", \"watermark_amplitude\": 0.4}".data(using: .utf8), builtInJSON: builtIn))
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: "{\"watermark_key\": \"\(key)\", \"watermark_amplitude\": 9}".data(using: .utf8), builtInJSON: builtIn))
        XCTAssertThrowsError(try SecutgConfigLoader.resolve(userFileJSON: "{\"watermark_key\": \"\(key)\", \"watermark_amplitude\": \"2\"}".data(using: .utf8), builtInJSON: builtIn))
    }
}
