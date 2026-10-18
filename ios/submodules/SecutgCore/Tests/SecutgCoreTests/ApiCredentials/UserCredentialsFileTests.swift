import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.40.1 / 3.40.3 on Apple platforms: the user's pair in `Application Support/secutg.json`, its effect on
/// the loader, and what the status reports. Uses temporary files only — never the real secutg.json.
final class UserCredentialsFileTests: XCTestCase {
    private let hashA = "0123456789abcdef0123456789abcdef"
    private let hashB = "fedcba9876543210fedcba9876543210"
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("secutg-a1q-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func pair(_ id: Int32, _ hash: String) -> ApiCredentialRules.Credentials {
        return ApiCredentialRules.Credentials(apiId: id, apiHash: hash)
    }

    private func json(_ object: [String: Any]) -> Data {
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private var fullConfig: [String: Any] {
        return ["api_id": 111, "api_hash": hashA, "app_name": "secuTG",
                "crypto": ["epoch_days": 7, "epoch_tolerance": 1, "rekey_reminder_days": 30, "max_plaintext_chars": 4096]]
    }

    func testRecordsSaveRestoreAndSetAside() {
        let first = UserCredentialsFile.Records.empty.saving(pair(1, hashA))
        XCTAssertEqual(first, UserCredentialsFile.Records(current: pair(1, hashA), previous: nil))
        let second = first.saving(pair(2, hashB))
        XCTAssertEqual(second, UserCredentialsFile.Records(current: pair(2, hashB), previous: pair(1, hashA)))
        // saving the same pair again does not lose the previous one
        XCTAssertEqual(second.saving(pair(2, hashB)), second)
        XCTAssertEqual(second.restoringPrevious(), UserCredentialsFile.Records(current: pair(1, hashA), previous: nil))
        XCTAssertEqual(second.settingAside(), UserCredentialsFile.Records(current: nil, previous: pair(2, hashB)))
        XCTAssertEqual(UserCredentialsFile.Records.empty.settingAside(), .empty)
    }

    func testWritingKeepsEveryOtherKeyAndReadsBack() throws {
        let original = json(fullConfig.merging(["autoReply": ["on": true]]) { a, _ in a })
        let written = try XCTUnwrap(UserCredentialsFile.file(original, writing: UserCredentialsFile.Records(current: pair(5, hashB), previous: pair(4, hashA))))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertEqual(object["api_id"] as? Int, 111)
        XCTAssertEqual(object["api_hash"] as? String, hashA)
        XCTAssertNotNil(object["crypto"])
        XCTAssertNotNil(object["autoReply"])
        XCTAssertEqual(UserCredentialsFile.records(fromFile: written), UserCredentialsFile.Records(current: pair(5, hashB), previous: pair(4, hashA)))
        // clearing removes only the user's keys
        let cleared = try XCTUnwrap(UserCredentialsFile.file(written, writing: .empty))
        let clearedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: cleared) as? [String: Any])
        XCTAssertNil(clearedObject[UserCredentialsFile.currentKey])
        XCTAssertNil(clearedObject[UserCredentialsFile.previousKey])
        XCTAssertEqual(clearedObject["api_id"] as? Int, 111)
    }

    func testAFileHoldingOnlyTheUserPairIsRemovedWhenCleared() throws {
        let written = try XCTUnwrap(UserCredentialsFile.file(nil, writing: UserCredentialsFile.Records(current: pair(5, hashB), previous: nil)))
        XCTAssertNil(try UserCredentialsFile.file(written, writing: .empty))
    }

    func testAnUnparseableFileIsNeverOverwritten() {
        XCTAssertThrowsError(try UserCredentialsFile.file(Data("not json".utf8), writing: .empty))
    }

    func testDamagedRecordsReadAsAbsent() {
        let data = json([UserCredentialsFile.currentKey: ["api_id": "0012", "api_hash": hashA],
                         UserCredentialsFile.previousKey: ["api_id": true, "api_hash": hashA]])
        XCTAssertEqual(UserCredentialsFile.records(fromFile: data), .empty)
        XCTAssertEqual(UserCredentialsFile.records(fromFile: Data("[]".utf8)), .empty)
        XCTAssertEqual(UserCredentialsFile.records(fromFile: nil), .empty)
    }

    func testStoreWritesOwnerOnlyAndClears() throws {
        let url = tempDir.appendingPathComponent("secutg.json")
        let store = UserCredentialsStore(fileURL: url)
        try store.update { $0.saving(self.pair(9, self.hashB)) }
        XCTAssertEqual(store.load().current, pair(9, hashB))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // clearing a file that does not exist is fine
        try store.clear()
    }

    func testLoaderUsesTheUserPairAboveBothFiles() throws {
        let builtIn = json(fullConfig)
        let user = try XCTUnwrap(UserCredentialsFile.file(json(["api_id": 222, "api_hash": hashA]),
                                                          writing: UserCredentialsFile.Records(current: pair(333, hashB), previous: nil)))
        let overrides = ApiCredentialFiles.overrides([:], userFileJSON: user)
        let config = try SecutgConfigLoader.resolve(overrides: overrides, userFileJSON: user, builtInJSON: builtIn)
        XCTAssertEqual(config.apiId, 333)
        XCTAssertEqual(config.apiHash, hashB)
        // without a user pair the file's own top level still wins over the bundled file, as before 3.40
        let plain = try SecutgConfigLoader.resolve(overrides: ApiCredentialFiles.overrides([:], userFileJSON: json(["api_id": 222])),
                                                   userFileJSON: json(["api_id": 222]), builtInJSON: builtIn)
        XCTAssertEqual(plain.apiId, 222)
    }

    func testAWholeEnvPairBeatsTheUserPairButHalfAPairDoesNot() {
        let user = try! UserCredentialsFile.file(nil, writing: UserCredentialsFile.Records(current: pair(333, hashB), previous: nil))
        let whole = ApiCredentialFiles.overrides(["api_id": "7", "api_hash": hashA], userFileJSON: user)
        XCTAssertEqual(whole["api_id"], "7")
        let half = ApiCredentialFiles.overrides(["api_id": "7"], userFileJSON: user)
        XCTAssertEqual(half["api_id"], "333")
        XCTAssertEqual(half["api_hash"], hashB)
    }

    func testStatusSources() {
        let builtIn = json(fullConfig)
        let userOnly = try! UserCredentialsFile.file(nil, writing: UserCredentialsFile.Records(current: pair(333, hashB), previous: pair(1, hashA)))
        let user = ApiCredentialFiles.status(environment: [:], userFileJSON: userOnly, builtInJSON: builtIn)
        XCTAssertEqual(user.source, .user)
        XCTAssertEqual(user.inUse?.apiId, 333)
        XCTAssertEqual(user.previous, pair(1, hashA))
        XCTAssertEqual(user.bundled?.apiId, 111)

        let bundled = ApiCredentialFiles.status(environment: [:], userFileJSON: nil, builtInJSON: builtIn)
        XCTAssertEqual(bundled.source, .bundled)
        XCTAssertTrue(bundled.hasBundled)
        XCTAssertFalse(bundled.hasBundledAlternative(rejected: pair(111, hashA)))
        XCTAssertTrue(bundled.hasBundledAlternative(rejected: pair(333, hashB)))

        // macOS dev builds: no bundled file, the packager's pair at the top of the user-override file
        let macDev = ApiCredentialFiles.status(environment: [:], userFileJSON: json(fullConfig), builtInJSON: nil)
        XCTAssertEqual(macDev.source, .bundled)
        XCTAssertFalse(macDev.hasUser)

        let env = ApiCredentialFiles.status(environment: ["TG_TELEGRAM_API_ID": "5", "TG_TELEGRAM_API_HASH": hashA], userFileJSON: userOnly, builtInJSON: builtIn)
        XCTAssertEqual(env.source, .env)
        XCTAssertEqual(env.inUse?.apiId, 5)

        let none = ApiCredentialFiles.status(environment: [:], userFileJSON: nil, builtInJSON: nil)
        XCTAssertEqual(none.source, .none)
        XCTAssertNil(none.inUse)
        let compiled = none.withCompiledFallback(pair(9, hashA))
        XCTAssertEqual(compiled.source, .bundled)
        XCTAssertEqual(compiled.inUse?.apiId, 9)
        // in use, but never offered as option ③ / a restore target (PLAN.md 3.40.2: only a packaged secutg.json pair)
        XCTAssertFalse(compiled.hasBundled)
        XCTAssertFalse(compiled.hasBundledAlternative(rejected: nil))
        XCTAssertEqual(user.withCompiledFallback(pair(9, hashA)), user)
        let userWithoutFiles = ApiCredentialFiles.status(environment: [:], userFileJSON: userOnly, builtInJSON: nil)
        XCTAssertEqual(userWithoutFiles.withCompiledFallback(pair(9, hashA)), userWithoutFiles)
        XCTAssertFalse(userWithoutFiles.withCompiledFallback(pair(9, hashA)).hasBundled)
    }

    /// A build with no secutg.json at all: a file holding only the user's pair must resolve to that pair.
    func testUserPairAloneResolvesWithoutAnyPackagedFile() throws {
        let userOnly = try UserCredentialsFile.file(nil, writing: UserCredentialsFile.Records(current: pair(333, hashB), previous: nil))
        let config = try SecutgConfigLoader.resolve(overrides: ApiCredentialFiles.overrides([:], userFileJSON: userOnly),
                                                    userFileJSON: userOnly, builtInJSON: nil)
        XCTAssertEqual(config.apiId, 333)
        XCTAssertEqual(config.apiHash, hashB)
        XCTAssertEqual(config.appName, SecutgConfigLoader.defaultAppName)
        XCTAssertEqual(config.crypto, CryptoConfig.defaults)
    }

    /// When loading fails the app connects with the compiled pair; the status must say so, not "your own".
    func testStatusAfterLoadFailureReportsWhatIsReallyInUse() throws {
        let userOnly = try UserCredentialsFile.file(nil, writing: UserCredentialsFile.Records(current: pair(333, hashB), previous: pair(1, hashA)))
        let files = ApiCredentialFiles.status(environment: [:], userFileJSON: userOnly, builtInJSON: nil)
        XCTAssertEqual(files.source, .user)
        let real = files.afterLoadFailure(compiled: pair(9, hashA))
        XCTAssertEqual(real.source, .bundled)
        XCTAssertEqual(real.inUse?.apiId, 9)
        XCTAssertEqual(real.user?.apiId, 333)
        XCTAssertEqual(real.previous, pair(1, hashA))
        XCTAssertFalse(real.hasBundled)
        XCTAssertEqual(files.afterLoadFailure(compiled: nil).source, .none)
    }

    func testLooksLikeA1Q() {
        XCTAssertTrue(ApiCredentialRules.looksLikeA1Q(" A1Q:1:\(hashA)"))
        XCTAssertFalse(ApiCredentialRules.looksLikeA1Q("K1Q:abc"))
    }

    /// 3.40.3: option ③ taken in a run that must restart survives exactly that one restart.
    func testChoseBundledCarriesOverOneRestart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "secutg.test.\(UUID().uuidString)"))
        ApiCredentialSession.markChoseBundledForNextLaunch(defaults)
        let nextRun = ApiCredentialSession()
        nextRun.consumeChoseBundledFromLastRun(defaults)
        XCTAssertTrue(nextRun.choseBundled)
        let runAfter = ApiCredentialSession()
        runAfter.consumeChoseBundledFromLastRun(defaults)
        XCTAssertFalse(runAfter.choseBundled)
    }

    /// 3.40.2 amendment (2026-10-02): the launch reminder on the bundled pair, once per run; 〔稍后〕 / ③ for this run only.
    func testLaunchReminderOncePerRunOnTheBundledPair() {
        let pair = ApiCredentialRules.Credentials(apiId: 10, apiHash: String(repeating: "a", count: 32))
        let bundled = ApiCredentialStatus(source: .bundled, inUse: pair, hasEnv: false, user: nil, previous: nil, bundled: pair)
        let run = ApiCredentialSession()
        run.status = bundled
        XCTAssertFalse(run.takeLaunchReminder(isLoggedIn: false))
        XCTAssertTrue(run.takeLaunchReminder(isLoggedIn: true))
        XCTAssertFalse(run.takeLaunchReminder(isLoggedIn: true), "asked once per run")
        let nextRun = ApiCredentialSession()
        nextRun.status = bundled
        XCTAssertTrue(nextRun.takeLaunchReminder(isLoggedIn: true), "every launch")

        let choseBundled = ApiCredentialSession()
        choseBundled.status = bundled
        choseBundled.choseBundled = true
        XCTAssertFalse(choseBundled.takeLaunchReminder(isLoggedIn: true))

        let own = ApiCredentialSession()
        own.status = ApiCredentialStatus(source: .user, inUse: pair, hasEnv: false, user: pair, previous: nil, bundled: pair)
        XCTAssertFalse(own.takeLaunchReminder(isLoggedIn: true))

        let compiled = ApiCredentialSession()
        compiled.status = ApiCredentialStatus(source: .none, inUse: nil, hasEnv: false, user: nil, previous: nil, bundled: nil)
            .withCompiledFallback(pair)
        XCTAssertTrue(compiled.takeLaunchReminder(isLoggedIn: true), "the compiled-in pair is shared like a bundled one")
    }
}
