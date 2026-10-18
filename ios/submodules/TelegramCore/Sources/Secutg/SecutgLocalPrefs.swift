import Foundation
import Postbox
import SecutgCore

/// Per-account local state that lives *outside* the keyring, because the emergency wipe destroys
/// the keyring but these two things have opposite fates across it (PLAN.md 3.22.5 / 3.23.3):
///
///   - the wipe "consumed" marker MUST survive the wipe — it is the single deliberate survivor of
///     the local purge (PLAN.md 3.22.5), without which a logged-back-in account wipes itself once a
///     minute for thirty days;
///   - the stranger decisions (PLAN.md 3.23.3) and the onboarding card's "not now" memory
///     (PLAN.md 3.24.8) MUST be cleared by the wipe — "a wiped device has no memory of who it once
///     decided about" (Web `decisions.ts` / `memory.ts`).
///
/// All three are plain UserDefaults entries (no content, no key material): the marker holds a message
/// id and a timestamp, a decision is one of three words per user id, an onboarding memory is one of
/// "0" / "1" / "never" per chat id. UserDefaults is not touched by Telegram's own database purge, so
/// the marker survives naturally; the wipe orchestration calls `clearStrangerDecisions` and
/// `clearOnboardMemories` explicitly to drop the other two.
///
/// Keyed by account so a multi-account device keeps them apart. Every accessor is defensive: a
/// missing or malformed entry reads as "nothing", never a crash — this runs on the message path.
public enum SecutgLocalPrefs {
    private static let consumedPrefix = "secutg.wipe.consumed."
    private static let strangerPrefix = "secutg.stranger."
    private static let pairingDialogSeenPrefix = "secutg.pairingDialogSeen."

    private static var defaults: UserDefaults { return UserDefaults.standard }

    /// Keys every entry below per account, so a multi-account device keeps them apart. One definition,
    /// because two would eventually disagree and silently orphan one account's entries.
    public static func accountKey(_ accountPeerId: PeerId) -> String {
        return "\(accountPeerId.toInt64())"
    }

    // MARK: wipe consumed marker (PLAN.md 3.22.5)

    public static func readConsumed(accountKey: String) -> WipeScan.Consumed? {
        guard let raw = defaults.dictionary(forKey: consumedPrefix + accountKey),
              let userId = raw["user_id"] as? String,
              let messageId = (raw["message_id"] as? NSNumber)?.int64Value else { return nil }
        // Absent on a marker written before this field existed, and read as 0 — the lowest possible
        // watermark. Every phrase still inside the thirty-day window then outranks it, so the newest one
        // fires one more time; that wipe writes a marker with a real date and the alternation the
        // watermark exists to stop cannot restart. One extra wipe, once, per upgraded device. The other
        // available default, "assume very new", fails in the opposite and worse direction: a device
        // silently deaf to a real trigger, which is the one thing this feature must never be.
        let triggerDate = (raw["trigger_date"] as? NSNumber)?.int64Value ?? 0
        let executedAt = (raw["executed_at"] as? NSNumber)?.int64Value ?? 0
        return WipeScan.Consumed(userId: userId, messageId: messageId,
                                 triggerDate: triggerDate, executedAt: executedAt)
    }

    /// Written BEFORE the wipe runs (PLAN.md 3.22.5 / Web `wipeScan.ts`): the wipe ends by signing
    /// out, and a marker that never got written would send this device round the same loop a minute
    /// after the next login.
    public static func writeConsumed(_ consumed: WipeScan.Consumed, accountKey: String) {
        defaults.set([
            "user_id": consumed.userId,
            "message_id": NSNumber(value: consumed.messageId),
            // the trigger message's OWN date in unix SECONDS; "executed_at" beside it is this device's
            // clock in MILLISECONDS. Two quantities, two units, never interchangeable.
            "trigger_date": NSNumber(value: consumed.triggerDate),
            "executed_at": NSNumber(value: consumed.executedAt),
        ], forKey: consumedPrefix + accountKey)
    }

    // MARK: stranger decisions (PLAN.md 3.23.3)

    public static func strangerDecision(accountKey: String, userId: String) -> StrangerNotice.Decision {
        let raw = defaults.string(forKey: strangerPrefix + accountKey + "." + userId)
        return StrangerNotice.Decision(rawValue: raw ?? "") ?? .unasked
    }

    public static func setStrangerDecision(_ decision: StrangerNotice.Decision, accountKey: String, userId: String) {
        guard decision != .unasked else { return }
        defaults.set(decision.rawValue, forKey: strangerPrefix + accountKey + "." + userId)
    }

    /// Dropped by the emergency wipe (PLAN.md 3.23.3): a wiped device forgets who it decided about.
    /// The consumed marker is intentionally left in place. PLAN.md 3.23.7's two records go with the decisions:
    /// the re-arm marks by prefix (a separator follows the account, so another account whose id merely starts with
    /// the same digits is safe), the contacts baseline by its exact key.
    public static func clearStrangerDecisions(accountKey: String) {
        let prefixes = [strangerPrefix + accountKey + ".", strangerRearmPrefix + accountKey + "."]
        for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: strangerContactsPrefix + accountKey)
    }

    /// PLAN.md 3.23.7: forgets one peer's 3.23 decision — the 「不用」 memory and the 「检查」 result alike, since the
    /// result is nothing but the `.checked` decision read against Telegram's own cached count — so the question is
    /// asked again where the re-arm puts it.
    public static func clearStrangerDecision(accountKey: String, userId: String) {
        defaults.removeObject(forKey: strangerPrefix + accountKey + "." + userId)
    }

    // MARK: re-arming the stranger notice after a contact is removed (PLAN.md 3.23.7)

    /// `secutg.strangerContacts.<account>`: the peers this account last saw in its contacts list, and
    /// `secutg.strangerRearm.<account>.<user>`: the re-arm mark's boundary. Same backend and same fate as the
    /// decisions above — local only, never synced (each device observes the removal and arms on its own), and
    /// dropped by the emergency wipe. The rules that read them are `StrangerRearm` in SecutgCore, under test.
    private static let strangerContactsPrefix = "secutg.strangerContacts."
    private static let strangerRearmPrefix = "secutg.strangerRearm."

    /// nil when no baseline was ever recorded: the first observation after an upgrade only takes note, because a
    /// removal this client never witnessed must not arm a chat out of nowhere (`StrangerRearm.observe`).
    public static func strangerLastSeenContacts(accountKey: String) -> Set<Int64>? {
        guard let raw = defaults.array(forKey: strangerContactsPrefix + accountKey) as? [NSNumber] else { return nil }
        return Set(raw.map { $0.int64Value })
    }

    public static func setStrangerLastSeenContacts(_ peerIds: Set<Int64>, accountKey: String) {
        defaults.set(peerIds.sorted().map { NSNumber(value: $0) }, forKey: strangerContactsPrefix + accountKey)
    }

    /// The mark's boundary — the largest message id known in the chat when the removal was observed — or nil when
    /// the chat is not marked.
    public static func strangerRearmBoundary(accountKey: String, userId: String) -> Int32? {
        guard let number = defaults.object(forKey: strangerRearmPrefix + accountKey + "." + userId) as? NSNumber else { return nil }
        return number.int32Value
    }

    /// nil clears the mark.
    public static func setStrangerRearmBoundary(_ boundary: Int32?, accountKey: String, userId: String) {
        let key = strangerRearmPrefix + accountKey + "." + userId
        if let boundary = boundary {
            defaults.set(NSNumber(value: boundary), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: onboarding card memory (PLAN.md 3.24.8)

    /// How many times the 3.24 encryption guide was waved away in this chat. Same backend and same
    /// failure handling as the stranger decisions above, and deliberately **not** the keyring: it is
    /// neither key material nor a setting, only the memory of a couple of clicks.
    ///
    /// Anything unreadable reads as "nobody was ever asked" — the decision, and the reason for it,
    /// live in `OnboardMemoryCodec.parse`, under test in SecutgCore: a memory we cannot understand
    /// must not be able to switch the card off for good.
    public static func onboardMemory(accountKey: String, chatId: String) -> OnboardMemory {
        return OnboardMemoryCodec.parse(defaults.string(forKey: OnboardMemoryCodec.storageKey(accountKey: accountKey, chatId: chatId)))
    }

    /// Losing this costs one repeated question, never correctness, so a failure here is swallowed
    /// the way the Web port swallows a blocked `localStorage` — there is nothing useful to tell the
    /// user and nothing to retry.
    public static func setOnboardMemory(_ memory: OnboardMemory, accountKey: String, chatId: String) {
        defaults.set(OnboardMemoryCodec.serialize(memory), forKey: OnboardMemoryCodec.storageKey(accountKey: accountKey, chatId: chatId))
    }

    /// Dropped by the emergency wipe (PLAN.md 3.24.8 table, last row): the same fate as the 3.23
    /// decisions, for the same reason.
    public static func clearOnboardMemories(accountKey: String) {
        let prefix = OnboardMemoryCodec.accountPrefix(accountKey: accountKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: fold runs this device cannot decrypt (PLAN.md 3.17 rule 5)

    /// Whether the message list collapses runs of unreadable messages into one line. Same backend and same
    /// failure handling as the two records above, and deliberately **not** the keyring: it is not key material,
    /// it is a preference about how a list is drawn, and the keyring travels between devices (PLAN.md 3.14)
    /// where a display choice has no business going.
    ///
    /// The default, and every failure, is **show everything** — `FoldPreferenceCodec.parse` in SecutgCore holds
    /// the decision and the reason for it, under test: a record we cannot understand must never be the reason a
    /// message is missing from the timeline.
    public static func foldsUndecryptable(accountKey: String) -> Bool {
        return FoldPreferenceCodec.parse(defaults.string(forKey: FoldPreferenceCodec.storageKey(accountKey: accountKey)))
    }

    /// Off is written as the *absence* of the record, so a device that never folded carries nothing and the
    /// fallback for "nothing" is already the right answer.
    public static func setFoldsUndecryptable(_ isEnabled: Bool, accountKey: String) {
        let key = FoldPreferenceCodec.storageKey(accountKey: accountKey)
        if let value = FoldPreferenceCodec.serialize(isEnabled) {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Dropped by the emergency wipe (PLAN.md 3.16), like the two records above.
    ///
    /// **By exact key, not by prefix.** Account keys are decimal peer ids, so this account's key is a literal
    /// prefix of another account's whenever one id starts with the other's digits; the 3.23 and 3.24.8 sweeps are
    /// safe only because a further separator follows the account there, and nothing follows it here.
    public static func clearFoldPreference(accountKey: String) {
        defaults.removeObject(forKey: FoldPreferenceCodec.storageKey(accountKey: accountKey))
    }

    // MARK: security check-up (PLAN.md 3.46)

    /// Finding id → when the user pressed 〔忽略〕 (ms). Format and failure handling are `SecurityAuditPrefs` in
    /// SecutgCore: anything unreadable reads as "nothing ignored", so a damaged record can only show more, never less.
    public static func auditIgnored(accountKey: String) -> [String: Int64] {
        return SecurityAuditPrefs.parseIgnored(defaults.string(forKey: SecurityAuditPrefs.ignoredKey(accountKey: accountKey)))
    }

    public static func setAuditIgnored(_ ignored: [String: Int64], accountKey: String) {
        defaults.set(SecurityAuditPrefs.serializeIgnored(ignored), forKey: SecurityAuditPrefs.ignoredKey(accountKey: accountKey))
    }

    /// Check 3's N as set on the page; 90 by default.
    public static func auditGroupKeyMaxAgeDays(accountKey: String) -> Int {
        return SecurityAuditPrefs.parseGroupKeyDays(defaults.string(forKey: SecurityAuditPrefs.groupKeyDaysKey(accountKey: accountKey)))
    }

    public static func setAuditGroupKeyMaxAgeDays(_ days: Int, accountKey: String) {
        guard let value = SecurityAuditPrefs.serializeGroupKeyDays(days) else { return }
        defaults.set(value, forKey: SecurityAuditPrefs.groupKeyDaysKey(accountKey: accountKey))
    }

    /// Check 7: when this device last exported a whole-keyring backup (ms); nil = never.
    public static func auditLastBackupMs(accountKey: String) -> Int64? {
        return SecurityAuditPrefs.parseLastBackupMs(defaults.string(forKey: SecurityAuditPrefs.lastBackupKey(accountKey: accountKey)))
    }

    public static func noteAuditBackup(accountKey: String, atMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0)) {
        defaults.set(String(atMs), forKey: SecurityAuditPrefs.lastBackupKey(accountKey: accountKey))
    }

    /// Dropped by the emergency wipe (PLAN.md 3.16), by exact key like the fold preference.
    public static func clearAuditPrefs(accountKey: String) {
        for key in SecurityAuditPrefs.allKeys(accountKey: accountKey) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: catch-up watermarks (PLAN.md 3.47)

    /// Per chat, the highest message id the catch-up pass has looked at; nil = never enabled (the pass then starts
    /// every chat at its current top). Local to this device and never in the keyring, so never in a backup — the
    /// format and its failure handling are `CatchUpWatermarks` in SecutgCore.
    public static func catchUpWatermarks(accountKey: String) -> CatchUpWatermarks? {
        return CatchUpWatermarks.parse(defaults.string(forKey: CatchUpWatermarks.storageKey(accountKey: accountKey)))
    }

    public static func setCatchUpWatermarks(_ marks: CatchUpWatermarks, accountKey: String) {
        defaults.set(marks.serialize(), forKey: CatchUpWatermarks.storageKey(accountKey: accountKey))
    }

    /// Dropped by the emergency wipe (PLAN.md 3.16), by exact key.
    public static func clearCatchUpWatermarks(accountKey: String) {
        defaults.removeObject(forKey: CatchUpWatermarks.storageKey(accountKey: accountKey))
    }

    // MARK: chats this device showed a code for (PLAN.md 3.46.1 step 3)

    /// Chat id + time only, never a key or the code itself; capped and de-duplicated by `LostDeviceGuide`.
    public static func lostDeviceShownCodes(accountKey: String) -> [LostDeviceGuide.ShownCode] {
        return LostDeviceGuide.parseShownCodes(defaults.string(forKey: LostDeviceGuide.shownCodesKey(accountKey: accountKey)))
    }

    /// Written when the share QR is produced (`SecutgV2Join.presentShare`).
    public static func noteLostDeviceShownCode(accountKey: String, chatId: String, atMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0)) {
        let next = LostDeviceGuide.recording(lostDeviceShownCodes(accountKey: accountKey), chatId: chatId, atMs: atMs)
        defaults.set(LostDeviceGuide.serializeShownCodes(next), forKey: LostDeviceGuide.shownCodesKey(accountKey: accountKey))
    }

    /// Dropped by the emergency wipe (PLAN.md 3.46.1: "随 3.16 擦除一并清除"), by exact key.
    public static func clearLostDeviceShownCodes(accountKey: String) {
        defaults.removeObject(forKey: LostDeviceGuide.shownCodesKey(accountKey: accountKey))
    }

    // MARK: pairing-complete dialog catch-up marker (PLAN.md 3.7.1)

    /// The `pairedAt` this device last showed the "配对完成" safety-code dialog for, or nil if it never
    /// has. Compared against the chat's *current* `pairedAt` by `PairingDialogCatchUp.isDue` (SecutgCore)
    /// — a mismatch (including "never shown") means the dialog is due, whether that is because the live
    /// event was never heard or because a later re-pairing produced a new episode. Deliberately **not**
    /// in the keyring: it is not key material and it is not a setting that should travel with a K1
    /// transfer to another of this account's own devices, which has its own independent "have I shown
    /// this" history. Not cleared by the emergency wipe — a wiped chat has no `pairedAt` to match against
    /// any more, so a leftover marker here is inert on its own, the same way an orphaned entry would be.
    public static func lastSeenPairingDialog(accountKey: String, chatId: String) -> Int64? {
        guard let number = defaults.object(forKey: pairingDialogSeenPrefix + accountKey + "." + chatId) as? NSNumber else { return nil }
        return number.int64Value
    }

    public static func setSeenPairingDialog(_ pairedAt: Int64, accountKey: String, chatId: String) {
        defaults.set(NSNumber(value: pairedAt), forKey: pairingDialogSeenPrefix + accountKey + "." + chatId)
    }

    // MARK: forced-logout notice (PLAN.md 3.46.2 §1)

    /// App-level, not per-account: by the time this is shown, the account's own records are already gone. Holds
    /// no account data — only "show the notice once" — and is cleared the moment it is shown.
    private static let sessionRevokedWipeNoticeKey = "secutg.sessionRevokedWipeNoticePending"

    public static func setSessionRevokedWipeNoticePending(_ value: Bool) {
        defaults.set(value, forKey: sessionRevokedWipeNoticeKey)
    }

    /// Reads and clears in one call: the notice is shown at most once per forced logout.
    public static func consumeSessionRevokedWipeNoticePending() -> Bool {
        let pending = defaults.bool(forKey: sessionRevokedWipeNoticeKey)
        if pending { defaults.removeObject(forKey: sessionRevokedWipeNoticeKey) }
        return pending
    }
}
