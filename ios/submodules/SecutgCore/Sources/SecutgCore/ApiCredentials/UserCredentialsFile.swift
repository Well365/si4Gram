import Foundation

/// PLAN.md 3.40.1 on Apple platforms: the user's own pair lives in `Application Support/secutg.json` — the
/// existing user-override file the config loader already reads — under its own key, `user_credentials`, with
/// the one before it under `user_credentials_previous` (3.40.3's 「恢复上一份」).
///
/// Why a key of its own rather than the file's top-level `api_id` / `api_hash`: on macOS that same file is where
/// the packager puts the whole configuration (the app bundle carries none), so its top-level pair is the
/// *bundled* layer of 3.40.1, not a choice the user made. Keeping the user's pair apart means the gate can tell
/// the two apart, 「先用内置凭据」 stays possible, and saving or wiping the user's pair never touches the rest of
/// the file. `SecutgConfigFiles.load` lifts this pair above the file's top level (`ApiCredentialFiles.overrides`).
///
/// Everything here is a pure function of the file's bytes; `UserCredentialsStore` does the reading and writing.
public enum UserCredentialsFile {
    public static let currentKey = "user_credentials"
    public static let previousKey = "user_credentials_previous"

    /// The stored records; both absent on a device that never chose.
    public struct Records: Equatable {
        public let current: ApiCredentialRules.Credentials?
        public let previous: ApiCredentialRules.Credentials?

        public init(current: ApiCredentialRules.Credentials?, previous: ApiCredentialRules.Credentials?) {
            self.current = current
            self.previous = previous
        }

        public static let empty = Records(current: nil, previous: nil)

        /// Saves a new pair; the one it replaces (if any, and if different) becomes 「上一份」.
        public func saving(_ credentials: ApiCredentialRules.Credentials) -> Records {
            guard let current = current, current != credentials else { return Records(current: credentials, previous: previous) }
            return Records(current: credentials, previous: current)
        }

        /// 「恢复上一份」 once the caller has decided `restoreTarget` is `.previous`.
        public func restoringPrevious() -> Records {
            return Records(current: previous, previous: nil)
        }

        /// Option ③ chosen while a user setting exists (〔更改凭据〕 after a rejection): it steps aside and stays
        /// restorable.
        public func settingAside() -> Records {
            guard let current = current else { return self }
            return Records(current: nil, previous: current)
        }
    }

    /// Reads both records out of the file's bytes. A damaged record reads as absent — the gate shows, never a crash.
    public static func records(fromFile data: Data?) -> Records {
        guard let object = jsonObject(data) else { return .empty }
        return Records(current: credentials(object[currentKey]), previous: credentials(object[previousKey]))
    }

    /// The file's new bytes with `records` written in and every other key left as it was. nil = the file would be
    /// empty: remove it rather than leave an empty trace behind (3.16).
    public static func file(_ data: Data?, writing records: Records) throws -> Data? {
        if data != nil && jsonObject(data) == nil {
            // A file we cannot parse belongs to someone else's edit; overwriting it would lose that edit silently.
            throw SecutgConfigError.invalidFile("secutg.json is not a JSON object; not writing the API credentials into it")
        }
        var object = jsonObject(data) ?? [:]
        object[currentKey] = records.current.map(serialize)
        object[previousKey] = records.previous.map(serialize)
        if object.isEmpty { return nil }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// The `api_id` / `api_hash` pair at the top of a secutg.json (the packager's layer), when it is a whole pair.
    public static func topLevelLayer(_ data: Data?) -> ApiCredentialRules.Layer? {
        guard let object = jsonObject(data) else { return nil }
        return ApiCredentialRules.Layer(apiId: apiId(object[SecutgConfigLoader.keyApiId]), apiHash: apiHash(object[SecutgConfigLoader.keyApiHash]))
    }

    private static func serialize(_ credentials: ApiCredentialRules.Credentials) -> [String: Any] {
        return [SecutgConfigLoader.keyApiId: NSNumber(value: credentials.apiId), SecutgConfigLoader.keyApiHash: credentials.apiHash]
    }

    private static func credentials(_ raw: Any?) -> ApiCredentialRules.Credentials? {
        guard let object = raw as? [String: Any],
              let id = apiId(object[SecutgConfigLoader.keyApiId]),
              let hash = apiHash(object[SecutgConfigLoader.keyApiHash]) else { return nil }
        return ApiCredentialRules.Credentials(apiId: id, apiHash: hash)
    }

    /// A JSON number (not a boolean) or a decimal string, validated by the 3.40.3 rules.
    private static func apiId(_ raw: Any?) -> Int32? {
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            guard number.doubleValue == number.doubleValue.rounded(), number.doubleValue >= 1,
                  number.doubleValue <= Double(ApiCredentialRules.apiIdMax) else { return nil }
            return ApiCredentialRules.parseApiId(String(number.int64Value))
        }
        if let text = raw as? String { return ApiCredentialRules.parseApiId(text) }
        return nil
    }

    private static func apiHash(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        return ApiCredentialRules.normalizeApiHash(text)
    }

    static func jsonObject(_ data: Data?) -> [String: Any]? {
        guard let data = data, !data.isEmpty, let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return raw as? [String: Any]
    }
}

/// Reads and writes `UserCredentialsFile` records in one file. Writes are atomic and owner-only (0600): the hash is
/// a secret. Not thread-safe by itself — the screens that use it run on the main thread.
public final class UserCredentialsStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The default location, `Application Support/secutg.json`; nil when the system has no such directory.
    public static func standard() -> UserCredentialsStore? {
        return SecutgConfigFiles.defaultUserFileURL().map(UserCredentialsStore.init(fileURL:))
    }

    public func load() -> UserCredentialsFile.Records {
        return UserCredentialsFile.records(fromFile: try? Data(contentsOf: fileURL))
    }

    public func save(_ records: UserCredentialsFile.Records) throws {
        let existing = FileManager.default.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : nil
        guard let data = try UserCredentialsFile.file(existing, writing: records) else {
            if existing != nil { try FileManager.default.removeItem(at: fileURL) }
            return
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
    }

    public func update(_ change: (UserCredentialsFile.Records) -> UserCredentialsFile.Records) throws {
        try save(change(load()))
    }

    /// 3.16 emergency wipe: the user's pair is a trace of this device; the packager's fields in the file stay.
    public func clear() throws {
        try save(.empty)
    }
}
