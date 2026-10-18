import Foundation

/// Whether this device folds runs of messages it cannot open (PLAN.md 3.17 rule 5).
///
/// Deliberately **not** in the keyring: it is not key material, it is a preference about how a list is drawn,
/// and the keyring snapshot is carried between devices (PLAN.md 3.14) where a display choice has no business
/// travelling. It lives in the same backend as the 3.24.8 "not now" memories and the 3.23 stranger decisions
/// (`SecutgLocalPrefs`, i.e. UserDefaults), and the emergency wipe (PLAN.md 3.16) drops it with them.
///
/// Both directions fail soft towards **showing everything**. A preference we cannot read or write costs the
/// reader some noise; the other fallback would cost him a line saying somebody wrote to him, and rule 5 is
/// written around never paying that price. That is why the parsing lives here, next to `swift test`, rather
/// than in each client's storage layer: it is the part with the security-relevant failure mode.
public enum FoldPreferenceCodec {
    /// PLAN.md 3.17 rule 5 and Web A name this `secutg:filter:undecryptable`. iOS and macOS add the account and
    /// use the local separator, exactly as they already do for the 3.24.8 memories (`secutg:onboard:<chatId>`
    /// stored as `secutg.onboard.<account>.<chatId>`): one device can be signed into several accounts, and a
    /// display choice made in one has no reason to reach another.
    public static let canonicalKey = "secutg:filter:undecryptable"

    private static let prefix = "secutg.filter.undecryptable."

    /// The value that means "fold". One spelling on all five clients.
    private static let onToken = "1"

    /// **Removed by exact key, never by prefix.** Account keys are decimal peer ids, so
    /// `secutg.filter.undecryptable.1` is a literal prefix of `secutg.filter.undecryptable.12`; a prefix sweep
    /// would take another account's preference with it. The 3.24.8 keys can be swept because a chat id and a
    /// trailing separator follow the account there — here nothing does.
    public static func storageKey(accountKey: String) -> String {
        return prefix + accountKey
    }

    /// Anything that is not exactly `"1"` — absent, empty, hand-edited, half-written, written by a future build
    /// — reads as **show everything**. A preference we cannot understand must never be the reason a message is
    /// missing from the timeline.
    public static func parse(_ raw: String?) -> Bool {
        return raw == onToken
    }

    /// `"1"` when folding, the absence of the record otherwise: a device that never folded carries nothing, and
    /// the fallback for "nothing" is already the right answer.
    public static func serialize(_ isEnabled: Bool) -> String? {
        return isEnabled ? onToken : nil
    }
}
