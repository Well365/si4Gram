import Foundation

/// PLAN.md 3.40: everyone uses their own Telegram API credentials. The pure half — validation, the `A1Q`
/// share text, which source wins, the start-up gate's state machine and the rejection test. No storage,
/// no network, no UI: the file glue is `UserCredentialsFile`, the screens live in each app. Every client
/// implements the same rules against `vectors-a1q.json` (Web reference: `src/secutg/config/apiCredentials.ts`).
public enum ApiCredentialRules {
    /// The pair a user sets on this device (3.40.1).
    public struct Credentials: Equatable {
        public let apiId: Int32
        /// Always 32 lower-case hexadecimal characters.
        public let apiHash: String

        public init(apiId: Int32, apiHash: String) {
            self.apiId = apiId
            self.apiHash = apiHash
        }
    }

    /// One layer as read from somewhere: either field may be missing. Only a whole pair counts (3.40.1).
    public struct Layer: Equatable {
        public let apiId: Int32?
        public let apiHash: String?

        public init(apiId: Int32?, apiHash: String?) {
            self.apiId = apiId
            self.apiHash = apiHash
        }

        public var complete: Credentials? {
            guard let apiId = apiId, let apiHash = apiHash else { return nil }
            return Credentials(apiId: apiId, apiHash: apiHash)
        }
    }

    /// 3.40.1: env > user setting (this device) > bundled with the package. `none` = nothing anywhere.
    public enum Source: String, Equatable {
        case env
        case user
        case bundled
        case none
    }

    public enum FieldError: String, Equatable {
        case id
        case hash
    }

    public enum Validation: Equatable {
        case ok(Credentials)
        /// Every field that is wrong, in the order `[.id, .hash]`.
        case invalid([FieldError])
    }

    public static let a1qPrefix = "A1Q"
    /// `api_id` is a TL `int`, a signed 32-bit field.
    public static let apiIdMax: Int64 = 2_147_483_647

    /// The one trim every client uses (vectors-a1q.json): ASCII space, tab, CR and LF at either end, nothing else.
    /// Not `.whitespacesAndNewlines` — that strips NBSP and U+3000 but not a BOM, which JavaScript's and Java's
    /// trims each treat differently, so the same paste would pass on one client and fail on another.
    public static let edgeWhitespace = CharacterSet(charactersIn: " \t\r\n")

    public static func trimAsciiWhitespace(_ raw: String) -> String {
        return raw.trimmingCharacters(in: edgeWhitespace)
    }

    /// 3.40.3: trimmed, then 1–10 digits, no leading zero (one canonical text per id, so two devices never
    /// disagree about `007` and `7`), at most 2147483647. nil when invalid.
    public static func parseApiId(_ raw: String) -> Int32? {
        let text = trimAsciiWhitespace(raw)
        let scalars = Array(text.unicodeScalars)
        guard (1...10).contains(scalars.count), scalars.allSatisfy(isAsciiDigit), scalars[0] != "0" else { return nil }
        guard let value = Int64(text), value <= apiIdMax else { return nil }
        return Int32(value)
    }

    /// 3.40.3: trimmed, 32 hexadecimal characters; upper case is accepted and lowered.
    public static func normalizeApiHash(_ raw: String) -> String? {
        let text = trimAsciiWhitespace(raw)
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 32, scalars.allSatisfy(isAsciiHex) else { return nil }
        return text.lowercased()
    }

    /// Both form fields at once: every field that is wrong, not just the first.
    public static func validate(apiId: String, apiHash: String) -> Validation {
        let id = parseApiId(apiId)
        let hash = normalizeApiHash(apiHash)
        if let id = id, let hash = hash { return .ok(Credentials(apiId: id, apiHash: hash)) }
        var errors: [FieldError] = []
        if id == nil { errors.append(.id) }
        if hash == nil { errors.append(.hash) }
        return .invalid(errors)
    }

    /// 3.40.4: `A1Q:<api_id>:<api_hash>`, plain text, the hash always lower case. nil for an invalid pair —
    /// there is nothing to share then.
    public static func buildA1Q(_ credentials: Credentials) -> String? {
        guard let id = parseApiId(String(credentials.apiId)), let hash = normalizeApiHash(credentials.apiHash) else { return nil }
        return "\(a1qPrefix):\(id):\(hash)"
    }

    /// 3.40.4 "解析严格": exactly three `:`-separated fields, the prefix `A1Q` in upper case, a valid id and a valid
    /// hash. Only ASCII whitespace AROUND the whole text is forgiven (a paste usually carries a newline); anything else —
    /// a lower-case prefix, a space inside, a fourth field — is nil, which the UI shows as `SecutgApiScanBad`.
    public static func parseA1Q(_ text: String) -> Credentials? {
        let parts = trimAsciiWhitespace(text).components(separatedBy: ":")
        guard parts.count == 3, parts[0] == a1qPrefix else { return nil }
        // `parseApiId` / `normalizeApiHash` trim, which would let `A1Q: 1:…` through — refuse inner whitespace first
        guard parts.allSatisfy({ !$0.isEmpty && $0 == trimAsciiWhitespace($0) }) else { return nil }
        guard let id = parseApiId(parts[1]), let hash = normalizeApiHash(parts[2]) else { return nil }
        return Credentials(apiId: id, apiHash: hash)
    }

    /// True when the text looks like an A1Q code at all — for a scanner deciding which flow a QR belongs to.
    public static func looksLikeA1Q(_ text: String) -> Bool {
        return trimAsciiWhitespace(text).hasPrefix(a1qPrefix + ":")
    }

    /// 3.40.1: which source the app actually connects with. A layer counts only when it carries both fields —
    /// half a pair never wins over a whole one below it. The user layer is always a whole pair.
    public static func resolveSource(env: Layer?, user: Credentials?, bundled: Layer?) -> Source {
        if env?.complete != nil { return .env }
        if user != nil { return .user }
        if bundled?.complete != nil { return .bundled }
        return .none
    }

    public struct GateInput: Equatable {
        /// Env carries a full pair: the operator chose for this install, the gate never shows.
        public let hasEnv: Bool
        public let hasUser: Bool
        public let hasBundled: Bool
        /// Option ③ was picked in this run of the app (carried over exactly one relaunch by 「恢复上一份」).
        public let choseBundled: Bool

        public init(hasEnv: Bool, hasUser: Bool, hasBundled: Bool, choseBundled: Bool) {
            self.hasEnv = hasEnv
            self.hasUser = hasUser
            self.hasBundled = hasBundled
            self.choseBundled = choseBundled
        }
    }

    public enum GateView: Equatable {
        case login
        case gate(showsBundledOption: Bool)
    }

    /// 3.40.2 (with the 2026-10-02 amendment): the gate stands in front of every login screen — QR login, phone login,
    /// adding an account — until this device has a pair it chose. Another account already logged in here no longer
    /// skips it; option ③ lets this run go on with the bundled pair.
    public static func gateView(_ input: GateInput) -> GateView {
        if input.hasEnv || input.hasUser { return .login }
        if input.choseBundled && input.hasBundled { return .login }
        return .gate(showsBundledOption: input.hasBundled)
    }

    public struct ReminderInput: Equatable {
        /// The source this run connects with (the compiled fallback counts as bundled, see `withCompiledFallback`).
        public let source: Source
        /// An account's main screen is up.
        public let isLoggedIn: Bool
        /// 〔稍后〕 was pressed, or the reminder was already answered, in this run.
        public let laterThisRun: Bool
        /// Option ③ was picked on the gate in this run: the user already said "the bundled pair, for now".
        public let choseBundled: Bool

        public init(source: Source, isLoggedIn: Bool, laterThisRun: Bool, choseBundled: Bool) {
            self.source = source
            self.isLoggedIn = isLoggedIn
            self.laterThisRun = laterThisRun
            self.choseBundled = choseBundled
        }
    }

    /// 3.40.2 amendment (2026-10-02), after login: while the bundled pair is in use the set-up page pops up on every
    /// launch with 〔现在设置〕〔稍后〕 — replacing the one-time `SecutgApiUpgradeNotice`. 〔稍后〕 lasts for this run only.
    public static func shouldRemind(_ input: ReminderInput) -> Bool {
        return input.source == .bundled && input.isLoggedIn && !input.laterThisRun && !input.choseBundled
    }

    /// 3.40.2 item 3: a new pair takes effect only through a restart — the connection is built with it.
    public static let saveNeedsRestart = true

    public enum RestoreTarget: String, Equatable {
        case previous
        case bundled
        case gate
    }

    /// 3.40.3 「恢复上一份」: the previous user setting; without one, the bundled pair (when it is not the pair that
    /// was just rejected); without that, the gate.
    public static func restoreTarget(hasPrevious: Bool, hasBundledAlternative: Bool) -> RestoreTarget {
        if hasPrevious { return .previous }
        return hasBundledAlternative ? .bundled : .gate
    }

    private static let rejectionErrors: Set<String> = ["API_ID_INVALID", "API_ID_PUBLISHED_FLOOD", "API_HASH_INVALID"]

    /// 3.40.3: the server errors that mean "this pair is not accepted" — the login screen turns them into
    /// `SecutgApiRejected` with a way out. Matched by prefix as well as by name, because Telegram adds `API_ID_*`
    /// variants without notice.
    public static func isRejection(_ errorCode: String?) -> Bool {
        guard let code = errorCode, !code.isEmpty else { return false }
        return rejectionErrors.contains(code) || code.hasPrefix("API_ID_") || code.hasPrefix("API_HASH_")
    }

    private static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
        return scalar.value >= 0x30 && scalar.value <= 0x39
    }

    private static func isAsciiHex(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x46) || (v >= 0x61 && v <= 0x66)
    }
}
