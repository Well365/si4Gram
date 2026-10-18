import Foundation

/// PLAN.md 3.46 安全体检: the checks, as one pure function over a snapshot of this device's state.
///
/// The snapshot holds states, times and counts only — never message text, never a key — and neither it nor the
/// findings are written anywhere or logged. Every client runs the same rules against
/// `vectors-security-audit.json` (Web reference: `src/secutg/audit/securityAudit.ts`, whose vector file's
/// `schema` field documents the input below).
public enum SecurityAudit {
    public enum Level: String, Equatable {
        case risk
        case warn
        case ok
        /// PLAN.md 3.46 补充（2026-10-04）: the page opened before check 12 or 13 finished reading Telegram —
        /// the 10s timeout was hit, or the read failed. No verdict, and not counted by `summarize`.
        case unavailable

        var rank: Int {
            switch self {
            case .risk: return 0
            case .warn: return 1
            case .ok: return 2
            case .unavailable: return 3
            }
        }
    }

    /// Where 〔去处理〕 goes. Each UI maps it to its own screen; `none` shows no button.
    public enum Action: String, Equatable {
        case openChat
        case openSafetyCode
        case openLockMenu
        case openLocalCiphertext
        case openBackup
        case openApiCredentials
        case openWipeSettings
        case openAssistant
        /// PLAN.md 3.46.2 check 12: the upstream two-step verification settings page.
        case openTwoStep
        /// PLAN.md 3.46.2 check 13: 〔丢了设备？〕's step 1 (the device list).
        case openSessions
        case none
    }

    /// Check 1's pairing state of one private chat: `conflict` = another device of this account holds the pairing
    /// (搁置), `suspended` = sending paused while a replacement key is set up (挂起), `mismatch` = safety codes
    /// differ and sending is blocked, `mismatchOverride` = the same but the user chose to keep sending.
    public enum Pairing: String, Equatable {
        case none
        case paired
        case waiting
        case conflict
        case suspended
        case mismatch
        case mismatchOverride = "mismatch_override"
    }

    public enum ChatKind: String, Equatable {
        case privateChat = "private"
        case group
        case saved
    }

    public struct Chat: Equatable {
        public let chatId: String
        public let kind: ChatKind
        public let pairing: Pairing
        public let verified: Bool
        public let inviteReceived: Bool
        /// An unanswered incoming invite from an identity the current pairing has never seen (3.43).
        public let keyChangedInvite: Bool
        public let hasKey: Bool
        /// Group only; nil = unknown.
        public let groupKeyCreatedMs: Int64?
        public let groupPasswordActive: Bool
        public let groupPasswordUnlocked: Bool
        /// 3.41: nil = the chat never had the switch (never encrypted); otherwise whether it is on.
        public let keyRequired: Bool?
        public let plaintextOnDisk: Bool
        /// 3.39.13: the key came from a V2Q clone — another device shares this chat's identity.
        public let cloned: Bool

        public init(chatId: String, kind: ChatKind, pairing: Pairing, verified: Bool, inviteReceived: Bool,
                    keyChangedInvite: Bool, hasKey: Bool, groupKeyCreatedMs: Int64?, groupPasswordActive: Bool,
                    groupPasswordUnlocked: Bool, keyRequired: Bool?, plaintextOnDisk: Bool, cloned: Bool) {
            self.chatId = chatId
            self.kind = kind
            self.pairing = pairing
            self.verified = verified
            self.inviteReceived = inviteReceived
            self.keyChangedInvite = keyChangedInvite
            self.hasKey = hasKey
            self.groupKeyCreatedMs = groupKeyCreatedMs
            self.groupPasswordActive = groupPasswordActive
            self.groupPasswordUnlocked = groupPasswordUnlocked
            self.keyRequired = keyRequired
            self.plaintextOnDisk = plaintextOnDisk
            self.cloned = cloned
        }
    }

    public struct Settings: Equatable {
        /// Check 3's N, adjustable on the page; <= 0 means the default.
        public let groupKeyMaxAgeDays: Int
        public let localCiphertext: Bool
        /// A custom wipe phrase is set (the built-in one always exists).
        public let wipePhraseSet: Bool
        /// This device acts on a wipe phrase found in Saved Messages.
        public let wipeListens: Bool
        public let netGateEnabled: Bool
        public let apiCredentialSource: ApiCredentialRules.Source

        public init(groupKeyMaxAgeDays: Int, localCiphertext: Bool, wipePhraseSet: Bool, wipeListens: Bool,
                    netGateEnabled: Bool, apiCredentialSource: ApiCredentialRules.Source) {
            self.groupKeyMaxAgeDays = groupKeyMaxAgeDays
            self.localCiphertext = localCiphertext
            self.wipePhraseSet = wipePhraseSet
            self.wipeListens = wipeListens
            self.netGateEnabled = netGateEnabled
            self.apiCredentialSource = apiCredentialSource
        }
    }

    /// Checks 12/13 (PLAN.md 3.46.2): read once from Telegram when the page opens, never from secuTG's own
    /// state. `nil` fields mean the read failed or was not attempted — "unknown", never a finding.
    public struct Account: Equatable {
        public let twoStepPassword: Bool?
        public let otherSessions: Int?
        /// PLAN.md 3.46 补充（2026-10-04）: this field's own read hit the page's 10s timeout (or failed)
        /// rather than simply never having been attempted — the matching check then reports `.unavailable`
        /// instead of staying silent.
        public let twoStepUnavailable: Bool
        public let otherSessionsUnavailable: Bool

        public init(twoStepPassword: Bool?, otherSessions: Int?, twoStepUnavailable: Bool = false, otherSessionsUnavailable: Bool = false) {
            self.twoStepPassword = twoStepPassword
            self.otherSessions = otherSessions
            self.twoStepUnavailable = twoStepUnavailable
            self.otherSessionsUnavailable = otherSessionsUnavailable
        }

        /// What a snapshot with no account read at all reports: both unknown, so neither check fires.
        public static let unknown = Account(twoStepPassword: nil, otherSessions: nil)
    }

    /// Check 11, macOS only; nil everywhere else.
    public struct Assistant: Equatable {
        public let enabled: Bool
        public let dataDir: String
        public let serveConnected: Bool
        public let unconfirmedEvents: Int

        public init(enabled: Bool, dataDir: String, serveConnected: Bool, unconfirmedEvents: Int) {
            self.enabled = enabled
            self.dataDir = dataDir
            self.serveConnected = serveConnected
            self.unconfirmedEvents = unconfirmedEvents
        }
    }

    public struct Snapshot: Equatable {
        public let chats: [Chat]
        public let settings: Settings
        /// Check 7: nil = never.
        public let lastBackupMs: Int64?
        public let lastKeyChangeMs: Int64?
        /// Check 10: dotted numeric versions; `newestPeerSeen` nil = nothing known, no finding.
        public let ownVersion: String?
        public let newestPeerSeen: String?
        public let assistant: Assistant?
        /// PLAN.md 3.46.2: `.unknown` (both fields nil) on a snapshot built before the page read Telegram, or
        /// when the read failed — checks 12/13 then report no finding, exactly like a missing field in the vectors.
        public let account: Account

        public init(chats: [Chat], settings: Settings, lastBackupMs: Int64?, lastKeyChangeMs: Int64?,
                    ownVersion: String?, newestPeerSeen: String?, assistant: Assistant?, account: Account = .unknown) {
            self.chats = chats
            self.settings = settings
            self.lastBackupMs = lastBackupMs
            self.lastKeyChangeMs = lastKeyChangeMs
            self.ownVersion = ownVersion
            self.newestPeerSeen = newestPeerSeen
            self.assistant = assistant
            self.account = account
        }
    }

    public enum Param: Equatable {
        case string(String)
        case int(Int64)
        case bool(Bool)

        /// The text a sentence placeholder shows.
        public var text: String {
            switch self {
            case let .string(value): return value
            case let .int(value): return String(value)
            case let .bool(value): return value ? "true" : "false"
            }
        }
    }

    public struct Finding: Equatable {
        /// `c<check>:<chatId or ->:<reason>` — stable across runs, what the ignore list is keyed by. Includes the
        /// reason, so a worse state re-surfaces at once.
        public let id: String
        public let check: Int
        public let level: Level
        public let chatId: String?
        /// Always has `reason`; the rest feed the sentence's placeholders.
        public let params: [String: Param]
        public let action: Action

        public init(id: String, check: Int, level: Level, chatId: String?, params: [String: Param], action: Action) {
            self.id = id
            self.check = check
            self.level = level
            self.chatId = chatId
            self.params = params
            self.action = action
        }

        public var reason: String { return params["reason"]?.text ?? "" }

        /// The sentence placeholders as `SecutgL10n` takes them.
        public var placeholders: [String: String] {
            var out: [String: String] = [:]
            for (key, value) in params where key != "reason" { out[key] = value.text }
            return out
        }
    }

    public struct Summary: Equatable {
        public let risk: Int
        public let warn: Int
        public let ok: Int

        public init(risk: Int, warn: Int, ok: Int) {
            self.risk = risk
            self.warn = warn
            self.ok = ok
        }
    }

    public static let msPerDay: Int64 = 86_400_000
    /// 3.46: an ignored finding comes back after 30 days.
    public static let ignoreDurationMs: Int64 = 30 * msPerDay
    public static let defaultGroupKeyMaxAgeDays = 90

    /// 3.46's `SecurityAudit.run(snapshot)`: every finding not currently ignored, sorted. `ignored` maps a finding
    /// id to when it was ignored (ms).
    public static func run(_ snapshot: Snapshot, nowMs: Int64, ignored: [String: Int64] = [:]) -> [Finding] {
        let limit = snapshot.settings.groupKeyMaxAgeDays > 0 ? snapshot.settings.groupKeyMaxAgeDays : defaultGroupKeyMaxAgeDays
        var drafts: [Finding] = []
        for chat in snapshot.chats {
            drafts += [checkPairing(chat), checkSafetyCode(chat), checkGroupKey(chat, nowMs: nowMs, limit: Int64(limit)), checkKeyRequired(chat)].compactMap { $0 }
        }
        drafts.append(checkLocalCiphertext(snapshot))
        drafts += checkClones(snapshot)
        drafts += [checkBackup(snapshot), checkApiSource(snapshot)].compactMap { $0 }
        drafts.append(checkWipe(snapshot))
        drafts += [checkVersion(snapshot), checkAssistant(snapshot), checkTwoStep(snapshot), checkOtherSessions(snapshot)].compactMap { $0 }
        return drafts.filter { !isIgnored($0, ignored: ignored, nowMs: nowMs) }.sorted(by: { compare($0, $1) < 0 })
    }

    public static func summarize(_ findings: [Finding]) -> Summary {
        return Summary(risk: findings.filter { $0.level == .risk }.count,
                       warn: findings.filter { $0.level == .warn }.count,
                       ok: findings.filter { $0.level == .ok }.count)
    }

    /// An ignore entry counts when it was made at most 30 days ago. A time in the future (the clock was ahead, or
    /// a hand-edited value) does not count at all — otherwise it would hide a risk until that time plus 30 days.
    /// Written without subtracting `at`, so no stored value (even `Int64.min`) can overflow and trap.
    public static func isIgnoreActive(_ at: Int64?, nowMs: Int64) -> Bool {
        guard let at = at else { return false }
        let (windowStart, overflow) = nowMs.subtractingReportingOverflow(ignoreDurationMs)
        return at <= nowMs && (overflow || at > windowStart)
    }

    /// Ignored and still within 30 days. An `ok` finding is never hidden — there is nothing to remind about.
    public static func isIgnored(_ finding: Finding, ignored: [String: Int64], nowMs: Int64) -> Bool {
        guard finding.level != .ok else { return false }
        return isIgnoreActive(ignored[finding.id], nowMs: nowMs)
    }

    /// The ignore list after ignoring `id` now, with entries past 30 days dropped (they no longer hide anything).
    public static func ignoring(_ ignored: [String: Int64], id: String, nowMs: Int64) -> [String: Int64] {
        var kept = ignored.filter { isIgnoreActive($0.value, nowMs: nowMs) }
        kept[id] = nowMs
        return kept
    }

    /// risk → warn → ok, then by check, then by chat (no chat first), then by id — total, so every client agrees.
    public static func compare(_ a: Finding, _ b: Finding) -> Int {
        if a.level.rank != b.level.rank { return a.level.rank < b.level.rank ? -1 : 1 }
        if a.check != b.check { return a.check < b.check ? -1 : 1 }
        let byChat = compareCodeUnits(a.chatId ?? "", b.chatId ?? "")
        if byChat != 0 { return byChat }
        return compareCodeUnits(a.id, b.id)
    }

    /// UTF-16 code-unit order (not locale order, not Swift's `String` order), the same in every language runtime.
    static func compareCodeUnits(_ a: String, _ b: String) -> Int {
        var left = a.utf16.makeIterator()
        var right = b.utf16.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (l?, r?):
                if l != r { return l < r ? -1 : 1 }
            }
        }
    }

    // MARK: the checks (rules in the vector file's `schema.rules`)

    private static func finding(_ check: Int, _ level: Level, _ reason: String, _ action: Action, chatId: String? = nil,
                                _ extra: [String: Param] = [:]) -> Finding {
        var params = extra
        params["reason"] = .string(reason)
        return Finding(id: "c\(check):\(chatId ?? "-"):\(reason)", check: check, level: level, chatId: chatId, params: params, action: action)
    }

    private static func checkPairing(_ chat: Chat) -> Finding? {
        guard chat.kind == .privateChat else { return nil }
        let c = chat.chatId
        if chat.keyChangedInvite { return finding(1, .risk, "keyChanged", .openChat, chatId: c) }
        if chat.pairing == .mismatch { return finding(1, .risk, "mismatch", .openChat, chatId: c) }
        if chat.inviteReceived { return finding(1, .warn, "invite", .openChat, chatId: c) }
        if chat.pairing == .suspended { return finding(1, .warn, "suspended", .openChat, chatId: c) }
        if chat.pairing == .conflict { return finding(1, .warn, "conflict", .openChat, chatId: c) }
        if chat.pairing == .paired || chat.pairing == .mismatchOverride { return finding(1, .ok, "paired", .openChat, chatId: c) }
        return nil
    }

    /// Only for a chat whose pairing is in use; a blocked mismatch is check 1's risk and not repeated here.
    private static func checkSafetyCode(_ chat: Chat) -> Finding? {
        guard chat.kind == .privateChat else { return nil }
        let c = chat.chatId
        if chat.pairing == .mismatchOverride { return finding(2, .risk, "mismatchOverride", .openSafetyCode, chatId: c) }
        guard chat.pairing == .paired || chat.pairing == .suspended else { return nil }
        return chat.verified
            ? finding(2, .ok, "verified", .openSafetyCode, chatId: c)
            : finding(2, .warn, "unverified", .openSafetyCode, chatId: c)
    }

    private static func checkGroupKey(_ chat: Chat, nowMs: Int64, limit: Int64) -> Finding? {
        // A locked password group may hold no usable key right now, and that is exactly what to report
        guard chat.kind == .group, chat.hasKey || chat.groupPasswordActive else { return nil }
        let c = chat.chatId
        let days = chat.groupKeyCreatedMs.map { max(0, floorDiv(nowMs - $0, msPerDay)) }
        let isLocked = chat.groupPasswordActive && !chat.groupPasswordUnlocked
        if let days = days, days > 2 * limit {
            return finding(3, .risk, "keyVeryOld", .openChat, chatId: c, ["days": .int(days), "limit": .int(limit)])
        }
        if let days = days, days > limit {
            return finding(3, .warn, "keyOld", .openChat, chatId: c, ["days": .int(days), "limit": .int(limit)])
        }
        if isLocked { return finding(3, .warn, "passwordLocked", .openChat, chatId: c, ["limit": .int(limit)]) }
        return finding(3, .ok, "fresh", .openChat, chatId: c, ["limit": .int(limit)])
    }

    private static func checkKeyRequired(_ chat: Chat) -> Finding? {
        guard let isOn = chat.keyRequired else { return nil }
        let c = chat.chatId
        if isOn { return finding(4, .ok, "on", .openLockMenu, chatId: c) }
        return chat.hasKey
            ? finding(4, .warn, "offWithKey", .openLockMenu, chatId: c)
            : finding(4, .risk, "offNoKey", .openLockMenu, chatId: c)
    }

    private static func checkLocalCiphertext(_ snapshot: Snapshot) -> Finding {
        if !snapshot.settings.localCiphertext { return finding(5, .risk, "off", .openLocalCiphertext) }
        let count = snapshot.chats.filter { $0.plaintextOnDisk }.count
        return count > 0
            ? finding(5, .warn, "plaintextHistory", .openLocalCiphertext, ["count": .int(Int64(count))])
            : finding(5, .ok, "on", .openLocalCiphertext)
    }

    /// No risk level: sharing an identity is a fact to remember, not a fault.
    private static func checkClones(_ snapshot: Snapshot) -> [Finding] {
        let cloned = snapshot.chats.filter { $0.cloned }
        if cloned.isEmpty { return [finding(6, .ok, "none", .none)] }
        return cloned.map { finding(6, .warn, "cloned", .openChat, chatId: $0.chatId) }
    }

    /// Nothing to back up (no chat holds a key) is not a finding at all — "never backed up" would be a false alarm.
    private static func checkBackup(_ snapshot: Snapshot) -> Finding? {
        guard snapshot.chats.contains(where: { $0.hasKey }) else { return nil }
        guard let lastBackup = snapshot.lastBackupMs else { return finding(7, .risk, "never", .openBackup) }
        if let lastChange = snapshot.lastKeyChangeMs, lastBackup < lastChange { return finding(7, .warn, "stale", .openBackup) }
        return finding(7, .ok, "current", .openBackup)
    }

    private static func checkApiSource(_ snapshot: Snapshot) -> Finding? {
        switch snapshot.settings.apiCredentialSource {
        case .user: return finding(8, .ok, "user", .openApiCredentials)
        case .env: return finding(8, .warn, "env", .openApiCredentials)
        case .bundled: return finding(8, .risk, "bundled", .openApiCredentials)
        case .none: return nil
        }
    }

    private static func checkWipe(_ snapshot: Snapshot) -> Finding {
        let settings = snapshot.settings
        if !settings.wipeListens { return finding(9, .risk, "notListening", .openWipeSettings) }
        if !settings.netGateEnabled { return finding(9, .risk, "netGateOff", .openWipeSettings) }
        if !settings.wipePhraseSet { return finding(9, .warn, "noCustomPhrase", .openWipeSettings) }
        return finding(9, .ok, "ready", .openWipeSettings)
    }

    /// Dotted numeric compare; a missing or non-numeric part counts as 0 (JavaScript `parseInt` semantics: the
    /// leading digits of a part, if any).
    static func compareVersions(_ a: String, _ b: String) -> (major: Int64, sign: Int) {
        let pa = a.components(separatedBy: ".").map(leadingInt)
        let pb = b.components(separatedBy: ".").map(leadingInt)
        var sign = 0
        for i in 0..<max(pa.count, pb.count) where sign == 0 {
            let l = i < pa.count ? pa[i] : 0
            let r = i < pb.count ? pb[i] : 0
            sign = l == r ? 0 : (l < r ? -1 : 1)
        }
        return ((pa.first ?? 0) - (pb.first ?? 0), sign)
    }

    private static func checkVersion(_ snapshot: Snapshot) -> Finding? {
        guard let own = snapshot.ownVersion, !own.isEmpty, let peer = snapshot.newestPeerSeen, !peer.isEmpty else { return nil }
        let (major, sign) = compareVersions(own, peer)
        let params: [String: Param] = ["version": .string(own), "peer": .string(peer)]
        if sign >= 0 { return finding(10, .ok, "current", .none, params) }
        return major < 0 ? finding(10, .risk, "majorBehind", .none, params) : finding(10, .warn, "behind", .none, params)
    }

    private static func checkAssistant(_ snapshot: Snapshot) -> Finding? {
        guard let assistant = snapshot.assistant else { return nil }
        if !assistant.enabled { return finding(11, .ok, "off", .openAssistant) }
        let params: [String: Param] = ["dir": .string(assistant.dataDir), "serveConnected": .bool(assistant.serveConnected),
                                       "count": .int(Int64(assistant.unconfirmedEvents))]
        return assistant.unconfirmedEvents > 0
            ? finding(11, .risk, "unconfirmed", .openAssistant, params)
            : finding(11, .warn, "on", .openAssistant, params)
    }

    /// PLAN.md 3.46.2 check 12: nil (not attempted) is silent; off is a risk, on is fine. PLAN.md 3.46 补充: an
    /// explicit timeout/failure (`twoStepUnavailable`) reports `.unavailable` rather than staying silent.
    private static func checkTwoStep(_ snapshot: Snapshot) -> Finding? {
        if snapshot.account.twoStepUnavailable { return finding(12, .unavailable, "unavailable", .openTwoStep) }
        guard let isSet = snapshot.account.twoStepPassword else { return nil }
        return isSet ? finding(12, .ok, "on", .openTwoStep) : finding(12, .risk, "off", .openTwoStep)
    }

    /// PLAN.md 3.46.2 check 13: nil is silent; one or more other sessions is a warning (with the count), none is
    /// fine. PLAN.md 3.46 补充: an explicit timeout/failure (`otherSessionsUnavailable`) reports `.unavailable`.
    private static func checkOtherSessions(_ snapshot: Snapshot) -> Finding? {
        if snapshot.account.otherSessionsUnavailable { return finding(13, .unavailable, "unavailable", .openSessions) }
        guard let count = snapshot.account.otherSessions else { return nil }
        return count > 0
            ? finding(13, .warn, "others", .openSessions, ["count": .int(Int64(count))])
            : finding(13, .ok, "none", .openSessions)
    }

    /// `parseInt(part, 10) || 0`: optional sign and leading digits; anything else is 0.
    private static func leadingInt(_ part: String) -> Int64 {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        var digits = ""
        var scalars = trimmed.unicodeScalars.makeIterator()
        var first = scalars.next()
        var negative = false
        if first == "-" || first == "+" {
            negative = first == "-"
            first = scalars.next()
        }
        var current = first
        while let scalar = current, scalar.value >= 0x30 && scalar.value <= 0x39, digits.count < 18 {
            digits.unicodeScalars.append(scalar)
            current = scalars.next()
        }
        guard let value = Int64(digits) else { return 0 }
        return negative ? -value : value
    }

    /// Math.floor for a possibly negative numerator (a key "made" in the future clamps to 0 afterwards anyway).
    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
