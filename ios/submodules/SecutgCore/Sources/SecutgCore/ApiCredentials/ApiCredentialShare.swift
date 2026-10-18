import Foundation

/// PLAN.md 3.40.1 for iOS app extensions (Share, NotificationService, NotificationContent, SiriIntents): they run in
/// their own processes and cannot read the main app's `Application Support/secutg.json`, so without this they would
/// connect with the compiled-in pair whatever the user set. The main app writes the pair it actually connects with
/// into the app-group container at start-up; each extension reads it, falling back to its compiled pair.
///
/// The file holds one pair, `{"api_id": N, "api_hash": "…"}`, owner-only (0600) and protected until first unlock
/// (the notification service runs while the device is locked). The app group is this app's own extensions only.
public enum ApiCredentialShare {
    public static let fileName = "secutg-api-pair.json"

    public static func url(appGroupPath: String) -> URL {
        return URL(fileURLWithPath: appGroupPath).appendingPathComponent(fileName)
    }

    private static let lock = NSLock()
    private static var writtenAppGroupPath: String?

    /// Main app, at start-up: the pair this run connects with. An invalid pair removes the file instead.
    public static func write(apiId: Int32, apiHash: String, appGroupPath: String) {
        lock.lock(); writtenAppGroupPath = appGroupPath; lock.unlock()
        let target = url(appGroupPath: appGroupPath)
        guard let id = ApiCredentialRules.parseApiId(String(apiId)), let hash = ApiCredentialRules.normalizeApiHash(apiHash) else {
            clear(appGroupPath: appGroupPath)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["api_id": Int(id), "api_hash": hash], options: [.sortedKeys]) else { return }
        if (try? Data(contentsOf: target)) == data { return }
        do {
            #if os(iOS)
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: target, options: [.atomic])
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            NSLog("[secutg] could not share the API pair with the app extensions (\(type(of: error)))")
        }
    }

    /// Extensions: the main app's pair, or nil (absent / unreadable / invalid) — then the compiled pair as before.
    public static func read(appGroupPath: String) -> ApiCredentialRules.Credentials? {
        return parse(try? Data(contentsOf: url(appGroupPath: appGroupPath)))
    }

    static func parse(_ data: Data?) -> ApiCredentialRules.Credentials? {
        guard let data = data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawId = object["api_id"] as? NSNumber, CFGetTypeID(rawId) != CFBooleanGetTypeID(),
              let id = ApiCredentialRules.parseApiId(rawId.stringValue),
              let rawHash = object["api_hash"] as? String, let hash = ApiCredentialRules.normalizeApiHash(rawHash) else { return nil }
        return ApiCredentialRules.Credentials(apiId: id, apiHash: hash)
    }

    /// Emergency wipe in the main app: the file this run wrote, wherever that was.
    public static func clearWritten() {
        lock.lock(); let path = writtenAppGroupPath; lock.unlock()
        if let path = path { clear(appGroupPath: path) }
    }

    /// Emergency wipe (3.16): the pair is a trace of this device; the next start writes whatever is then in use.
    public static func clear(appGroupPath: String) {
        let target = url(appGroupPath: appGroupPath)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.removeItem(at: target)
    }
}
