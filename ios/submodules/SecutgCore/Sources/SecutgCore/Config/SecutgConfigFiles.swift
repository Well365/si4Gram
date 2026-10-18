import Foundation

/// Locates the three configuration layers on Apple platforms and hands them to `SecutgConfigLoader`:
/// environment (`TG_TELEGRAM_API_ID`, `TG_TELEGRAM_API_HASH`, `TG_APP_NAME`, `TG_SECUTG_EPOCH_DAYS`, …)
/// > user file (`<Application Support>/secutg.json`) > bundled `secutg.json`. The user's own API pair (PLAN.md 3.40,
/// `user_credentials` in the user file) sits between the environment and the files.
public enum SecutgConfigFiles {
    public static let fileName = "secutg.json"

    static let envKeys: [String: String] = [
        "TG_TELEGRAM_API_ID": SecutgConfigLoader.keyApiId,
        "TG_TELEGRAM_API_HASH": SecutgConfigLoader.keyApiHash,
        "TG_APP_NAME": SecutgConfigLoader.keyAppName,
        "TG_SECUTG_EPOCH_DAYS": "\(SecutgConfigLoader.keyCrypto).\(SecutgConfigLoader.keyEpochDays)",
        "TG_SECUTG_EPOCH_TOLERANCE": "\(SecutgConfigLoader.keyCrypto).\(SecutgConfigLoader.keyEpochTolerance)",
        "TG_SECUTG_REKEY_REMINDER_DAYS": "\(SecutgConfigLoader.keyCrypto).\(SecutgConfigLoader.keyRekeyReminderDays)",
        "TG_SECUTG_MAX_PLAINTEXT_CHARS": "\(SecutgConfigLoader.keyCrypto).\(SecutgConfigLoader.keyMaxPlaintextChars)",
    ]

    public static func overrides(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var out = [String: String]()
        for (env, key) in envKeys {
            if let value = environment[env], !value.isEmpty { out[key] = value }
        }
        return out
    }

    /// Default user override location: `~/Library/Application Support/secutg.json` (sandboxed container on iOS).
    public static func defaultUserFileURL() -> URL? {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    public static func load(bundle: Bundle = .main, userFileURL: URL? = defaultUserFileURL(), environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SecutgConfig {
        let builtIn = bundle.url(forResource: "secutg", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        let user = userFileURL.flatMap { try? Data(contentsOf: $0) }
        // PLAN.md 3.40.1: the user's own pair (`user_credentials` in the user file) ranks below a whole env pair and
        // above both files' top-level fields — see `ApiCredentialFiles.overrides`.
        let layered = ApiCredentialFiles.overrides(overrides(from: environment), userFileJSON: user)
        return try SecutgConfigLoader.resolve(overrides: layered, userFileJSON: user, builtInJSON: builtIn)
    }
}
