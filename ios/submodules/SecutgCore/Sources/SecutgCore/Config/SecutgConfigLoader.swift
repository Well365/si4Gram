import Foundation

/// Merges three layers, highest priority first: overrides (environment / launch arguments) > user file JSON
/// (Application Support/secutg.json) > built-in JSON (bundle resource secutg.json). Fails fast with a clear
/// message when a required field is missing or malformed. Keys are snake_case like the shared file.
public enum SecutgConfigLoader {
    public static let keyApiId = "api_id"
    public static let keyApiHash = "api_hash"
    public static let keyAppName = "app_name"
    public static let keyCrypto = "crypto"
    public static let keyEpochDays = "epoch_days"
    public static let keyEpochTolerance = "epoch_tolerance"
    public static let keyRekeyReminderDays = "rekey_reminder_days"
    public static let keyMaxPlaintextChars = "max_plaintext_chars"
    public static let keyDistribution = "distribution"
    public static let keySponsor = "sponsor"
    public static let keyWatermarkKey = "watermark_key"
    public static let keyWatermarkAmplitude = "watermark_amplitude"
    /// The built-in default `app_name` (Web `BUILT_IN_DEFAULTS`, Android `secutg.defaults.json`).
    public static let defaultAppName = "secuTG"
    static let distributionKeys = ["version", "channel", "site", "source", "contact", "build", "relay_source", "assistant_source", "faq"]

    public static func resolve(overrides: [String: String] = [:], userFileJSON: Data?, builtInJSON: Data?) throws -> SecutgConfig {
        // Either layer may be absent (macOS dev builds ship no bundled file; iOS may run without a user file),
        // but at least one must exist so the failure names the real cause instead of a list of missing fields.
        guard builtInJSON != nil || userFileJSON != nil else {
            throw SecutgConfigError.invalidFile("no secutg.json found (neither bundled nor user file)")
        }
        let builtIn = try builtInJSON.map { try parseObject($0, label: "built-in secutg.json") } ?? [:]
        let user = try userFileJSON.map { try parseObject($0, label: "secutg.json") } ?? [:]

        let apiId = try firstInt(overrides[keyApiId], user, builtIn, keyApiId)
        let apiHash = try firstString(overrides[keyApiHash], user, builtIn, keyApiHash)
        // Built-in defaults below both files (as Web's BUILT_IN_DEFAULTS and Android's secutg.defaults.json), so a
        // user file holding nothing but the user's own pair (PLAN.md 3.40) resolves on a build that ships no file
        let appName = try firstString(overrides[keyAppName], user, builtIn, keyAppName) ?? defaultAppName
        let userCrypto = try optObject(user, keyCrypto, label: "secutg.json")
        let builtInCrypto = try optObject(builtIn, keyCrypto, label: "built-in secutg.json")

        var missing = [String]()
        if apiId == nil { missing.append(keyApiId) }
        if apiHash == nil { missing.append(keyApiHash) }
        let defaults = CryptoConfig.defaults
        let epochDays = try cryptoInt(overrides, userCrypto, builtInCrypto, keyEpochDays) ?? defaults.epochDays
        let epochTolerance = try cryptoInt(overrides, userCrypto, builtInCrypto, keyEpochTolerance) ?? defaults.epochTolerance
        let rekeyReminderDays = try cryptoInt(overrides, userCrypto, builtInCrypto, keyRekeyReminderDays) ?? defaults.rekeyReminderDays
        let maxPlaintextChars = try cryptoInt(overrides, userCrypto, builtInCrypto, keyMaxPlaintextChars) ?? defaults.maxPlaintextChars
        if !missing.isEmpty {
            throw SecutgConfigError.missingField("Missing required field(s): \(missing.joined(separator: ", ")). Provide them in the bundled secutg.json or the user secutg.json")
        }

        try assertPositive(keyApiId, apiId!)
        guard apiId! <= Int(Int32.max) else { throw SecutgConfigError.invalidField("`api_id` is out of range") }
        guard apiHash!.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil else {
            throw SecutgConfigError.invalidField("`api_hash` must be a 32-character hex string")
        }
        guard !appName.trimmingCharacters(in: .whitespaces).isEmpty else { throw SecutgConfigError.invalidField("`app_name` must not be empty") }
        try assertPositive("\(keyCrypto).\(keyEpochDays)", epochDays)
        guard epochTolerance >= 0 else { throw SecutgConfigError.invalidField("`crypto.epoch_tolerance` must be a non-negative integer, got \(epochTolerance)") }
        try assertPositive("\(keyCrypto).\(keyRekeyReminderDays)", rekeyReminderDays)
        try assertPositive("\(keyCrypto).\(keyMaxPlaintextChars)", maxPlaintextChars)

        // PLAN.md 3.11: distribution info is trusted from the bundled file only (overrides / user file ignored)
        let distribution = try readDistribution(try optObject(builtIn, keyDistribution, label: "built-in secutg.json"))
        // PLAN.md 3.15: the sponsor block is built-in only for the same reason — a repackaged build must not be able
        // to swap in its own payment codes.
        let sponsor = try readSponsor(try optObject(builtIn, keySponsor, label: "built-in secutg.json"))
        // PLAN.md 3.21: validated here rather than where it is drawn, so a typo shows up at startup instead of as a
        // watermark that silently traces to nothing.
        let watermark = try readWatermark(overrides, user, builtIn)
        return SecutgConfig(apiId: Int32(apiId!), apiHash: apiHash!, appName: appName,
                            crypto: CryptoConfig(epochDays: epochDays, epochTolerance: epochTolerance,
                                                 rekeyReminderDays: rekeyReminderDays, maxPlaintextChars: maxPlaintextChars),
                            distribution: distribution, sponsor: sponsor, watermark: watermark)
    }

    /// `watermark_key` is 32 bytes as 64 hex characters, or nothing at all. Malformed is refused, never quietly
    /// ignored; out-of-range amplitude is refused rather than clamped in silence (PLAN.md 3.21.2).
    private static func readWatermark(_ overrides: [String: String], _ user: [String: Any], _ builtIn: [String: Any]) throws -> WatermarkConfig? {
        guard let raw = try firstString(overrides[keyWatermarkKey], user, builtIn, keyWatermarkKey) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty { return nil }
        guard text.count == WatermarkCodec.projectKeyBytes * 2, let key = Hex.decode(text), key.count == WatermarkCodec.projectKeyBytes else {
            throw SecutgConfigError.invalidField("`\(keyWatermarkKey)` must be 64 hex characters (\(WatermarkCodec.projectKeyBytes) bytes)")
        }
        let amplitude = try firstDouble(overrides[keyWatermarkAmplitude], user, builtIn, keyWatermarkAmplitude) ?? WatermarkCarrier.amplitude
        guard amplitude.isFinite, amplitude >= WatermarkCarrier.amplitudeMin, amplitude <= WatermarkCarrier.amplitudeMax else {
            throw SecutgConfigError.invalidField("`\(keyWatermarkAmplitude)` must be between \(WatermarkCarrier.amplitudeMin) and \(WatermarkCarrier.amplitudeMax), got \(amplitude)")
        }
        return WatermarkConfig(projectKey: key, amplitude: amplitude)
    }

    /// Every field is optional; a present field must be a string.
    private static func readDistribution(_ object: [String: Any]?) throws -> DistributionConfig? {
        guard let object = object else { return nil }
        var values = [String: String]()
        for key in distributionKeys where object[key] != nil {
            values[key] = try readString(object, key, label: "built-in secutg.json `\(keyDistribution)`")
        }
        return DistributionConfig(version: values["version"], channel: values["channel"], site: values["site"],
                                  source: values["source"], contact: values["contact"], build: values["build"],
                                  relaySource: values["relay_source"], // PLAN.md 3.48.8 // SECUTG-HOOK
                                  assistantSource: values["assistant_source"], // PLAN.md 3.52
                                  faq: values["faq"]) // PLAN.md 3.53 // SECUTG-HOOK
    }

    /// Every field is optional; `qrs` / `addresses` carry `{label, value}` and `links` carry `{label, url}`.
    private static func readSponsor(_ object: [String: Any]?) throws -> SponsorConfig? {
        guard let object = object else { return nil }
        let label = "built-in secutg.json `\(keySponsor)`"
        var note: String?
        if object["note"] != nil {
            let value = try readString(object, "note", label: label)
            note = value.isEmpty ? nil : value
        }
        return SponsorConfig(note: note,
                             qrs: try readEntries(object, "qrs", valueKey: "value", label: label).map { SponsorEntry(label: $0.0, value: $0.1) },
                             links: try readEntries(object, "links", valueKey: "url", label: label).map { SponsorLink(label: $0.0, url: $0.1) },
                             addresses: try readEntries(object, "addresses", valueKey: "value", label: label).map { SponsorEntry(label: $0.0, value: $0.1) })
    }

    private static func readEntries(_ parent: [String: Any], _ key: String, valueKey: String, label: String) throws -> [(String, String)] {
        guard let raw = parent[key] else { return [] }
        guard let array = raw as? [Any] else { throw SecutgConfigError.invalidField("`\(key)` in \(label) must be an array") }
        return try array.map { element in
            guard let entry = element as? [String: Any] else { throw SecutgConfigError.invalidField("every item of `\(key)` in \(label) must be an object") }
            let entryLabel = try readString(entry, "label", label: "\(label) `\(key)`")
            let value = try readString(entry, valueKey, label: "\(label) `\(key)`")
            guard !entryLabel.isEmpty, !value.isEmpty else {
                throw SecutgConfigError.invalidField("`label` and `\(valueKey)` of every item of `\(key)` in \(label) must not be empty")
            }
            return (entryLabel, value)
        }
    }

    /// nil = not set in any layer; the caller falls back to `CryptoConfig.defaults` (nothing is "missing" any more).
    private static func cryptoInt(_ env: [String: String], _ user: [String: Any]?, _ builtIn: [String: Any]?, _ key: String) throws -> Int? {
        return try firstInt(env["\(keyCrypto).\(key)"], user, builtIn, key)
    }

    private static func firstInt(_ envValue: String?, _ user: [String: Any]?, _ builtIn: [String: Any]?, _ key: String) throws -> Int? {
        if let env = envValue, !env.isEmpty {
            guard let parsed = Int(env.trimmingCharacters(in: .whitespaces)) else {
                throw SecutgConfigError.invalidField("override `\(key)` must be an integer, got \"\(env)\"")
            }
            return parsed
        }
        if let user = user, user[key] != nil { return try readInt(user, key, label: "secutg.json") }
        if let builtIn = builtIn, builtIn[key] != nil { return try readInt(builtIn, key, label: "built-in secutg.json") }
        return nil
    }

    private static func firstDouble(_ envValue: String?, _ user: [String: Any], _ builtIn: [String: Any], _ key: String) throws -> Double? {
        if let env = envValue, !env.isEmpty {
            guard let parsed = Double(env.trimmingCharacters(in: .whitespaces)) else {
                throw SecutgConfigError.invalidField("override `\(key)` must be a number, got \"\(env)\"")
            }
            return parsed
        }
        for (object, label) in [(user, "secutg.json"), (builtIn, "built-in secutg.json")] where object[key] != nil {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw SecutgConfigError.invalidField("`\(key)` in \(label) must be a number")
            }
            return number.doubleValue
        }
        return nil
    }

    private static func firstString(_ envValue: String?, _ user: [String: Any], _ builtIn: [String: Any], _ key: String) throws -> String? {
        if let env = envValue, !env.isEmpty { return env }
        if user[key] != nil { return try readString(user, key, label: "secutg.json") }
        if builtIn[key] != nil { return try readString(builtIn, key, label: "built-in secutg.json") }
        return nil
    }

    private static func parseObject(_ data: Data?, label: String) throws -> [String: Any] {
        guard let data = data else { throw SecutgConfigError.invalidFile("\(label) is missing") }
        guard let raw = try? JSONSerialization.jsonObject(with: data), let object = raw as? [String: Any] else {
            throw SecutgConfigError.invalidFile("\(label) is not a JSON object")
        }
        return object
    }

    private static func optObject(_ parent: [String: Any], _ key: String, label: String) throws -> [String: Any]? {
        guard let value = parent[key] else { return nil }
        guard let object = value as? [String: Any] else { throw SecutgConfigError.invalidField("`\(key)` in \(label) must be an object") }
        return object
    }

    private static func readInt(_ object: [String: Any], _ key: String, label: String) throws -> Int {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded() else {
            throw SecutgConfigError.invalidField("`\(key)` in \(label) must be an integer")
        }
        return number.intValue
    }

    private static func readString(_ object: [String: Any], _ key: String, label: String) throws -> String {
        guard let value = object[key] as? String else { throw SecutgConfigError.invalidField("`\(key)` in \(label) must be a string") }
        return value
    }

    private static func assertPositive(_ label: String, _ value: Int) throws {
        guard value > 0 else { throw SecutgConfigError.invalidField("`\(label)` must be a positive integer, got \(value)") }
    }
}
