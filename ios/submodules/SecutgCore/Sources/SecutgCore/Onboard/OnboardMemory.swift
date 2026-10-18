import Foundation

/// How many times the onboarding card was waved away in one chat (PLAN.md 3.24.8), and the two
/// transitions that change it.
///
/// Counting rather than a boolean is what makes "twice" the rule instead of a flag someone later
/// reads as "dismissed once, hide forever".
///
/// Stored per chat, per account, in the same backend as the 3.23 stranger decisions
/// (`SecutgLocalPrefs`, i.e. UserDefaults) and deliberately **not** the keyring: this is neither key
/// material nor a setting, it is the memory of a couple of clicks. Losing it costs one repeated
/// question and nothing else, which is why every read falls back to "never asked" instead of
/// failing. The emergency wipe (PLAN.md 3.16) drops it along with the stranger decisions — a wiped
/// device must not remember which chats it was once asked about.
public enum OnboardMemory: Equatable {
    /// Times the user said "not now" here. Zero means nobody was ever asked.
    case count(Int)
    /// Retired for good: the second "not now", or "don't show this for this chat" on the compact row.
    case never

    /// Zero for `.never` is never read — `evaluate` returns `.hidden` before it gets this far — but
    /// a total function keeps callers from having to unwrap a case that cannot reach them.
    public var ignoredCount: Int {
        switch self {
        case let .count(value): return value
        case .never: return 0
        }
    }

    /// What to remember after a "not now" (PLAN.md 3.24.8): the first one shrinks the card to a
    /// single line, the second retires it for good. `.never` is final and cannot be walked back.
    public var afterNotNow: OnboardMemory {
        switch self {
        case .never: return .never
        case let .count(value): return value >= 1 ? .never : .count(1)
        }
    }

    /// What to remember after unpairing, which includes withdrawing an invitation (PLAN.md 3.24.5
    /// rule 3 and the 3.24.8 table): back to the guide, but counted as already ignored once, so it
    /// comes back as one collapsed line. Somebody who just switched encryption off does not need to
    /// be argued with on the spot — and this must never *lower* a count that is already higher.
    public var afterUnpair: OnboardMemory {
        switch self {
        case .never: return .never
        case let .count(value): return .count(max(value, 1))
        }
    }
}

/// The on-disk form of `OnboardMemory`, kept here rather than in the platform storage layer so the
/// parsing — the part with the security-relevant failure mode — is covered by `swift test` and is
/// byte-identical between iOS and macOS.
public enum OnboardMemoryCodec {
    private static let neverToken = "never"

    /// PLAN.md 3.24.8 names the key `secutg:onboard:<chatId>`. iOS and macOS add the account, the way
    /// the 3.23 decisions already do (`secutg.stranger.<account>.<user>`), because one device can be
    /// signed into several accounts and a "never" said in one account's chat must not silence the
    /// card in another's. The separator follows the same local convention, so the whole per-account
    /// prefix can be enumerated and dropped in one pass by the wipe.
    public static let prefix = "secutg.onboard."

    public static func storageKey(accountKey: String, chatId: String) -> String {
        return prefix + accountKey + "." + chatId
    }

    public static func accountPrefix(accountKey: String) -> String {
        return prefix + accountKey + "."
    }

    /// Anything unparseable — hand-edited, half-written, written by a future build — reads as
    /// unasked. **A memory we cannot understand must not be able to silence the card**: falling the
    /// other way would let one stray byte remove an encryption entry point for good, silently.
    public static func parse(_ raw: String?) -> OnboardMemory {
        guard let raw = raw else { return .count(0) }
        if raw == neverToken { return .never }
        guard let value = Int(raw), value > 0 else { return .count(0) }
        return .count(value)
    }

    /// `"0"` / `"1"` / `"never"`, the same three spellings on all five clients.
    public static func serialize(_ memory: OnboardMemory) -> String {
        switch memory {
        case .never: return neverToken
        case let .count(value): return String(value)
        }
    }
}
