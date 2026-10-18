import Foundation

/// The phrase that triggers the emergency wipe from Saved Messages (PLAN.md 3.22.2).
///
/// Saved Messages is the one channel only the account owner can write to, which is what makes a
/// plain phrase safe enough to be the trigger: knowing it buys nothing without the account. That
/// is also why it can be public — and being public is what lets you fire it from a borrowed phone
/// running the official client, with no secuTG installed and no key material to hand.
///
/// Pure Swift, no Telegram / UIKit dependency, so both iOS and macOS call the exact same code
/// (PLAN.md 3.22, CLAUDE.md: the decision logic is implemented once here).
public enum WipePhrase {
    /// Compiled in, always armed, cannot be switched off. Three repetitions so it is long enough
    /// (18 characters / 54 UTF-8 bytes) that nobody types it by accident. NOTE: PLAN.md 3.22.2 and
    /// Web A `phrase.ts` both describe this as "33 characters"; that count is inaccurate — the
    /// constant is 18 characters. The value itself is byte-for-byte identical across ports.
    ///
    /// Must stay byte-for-byte identical to Web A `phrase.ts` `BUILT_IN_WIPE_PHRASE` and the other
    /// ports, or a phrase posted from one client would not fire the wipe on another.
    public static let builtInPhrase = "紫色大象飞了紫色大象飞了紫色大象飞了"

    /// A custom phrase shorter than this is too easy to hit by accident to be allowed.
    public static let minCustomPhraseLength = 12

    /// How far back the Saved Messages scan looks (days). Older triggers are ignored so a phrase
    /// left lying around does not wipe a device restored from backup a year later.
    public static let scanDays = 30

    /// How long after login/start the first scan waits (ms), so the initial sync has the history.
    public static let scanDelayMs = 60_000

    /// Whether this message IS the phrase — the whole message, not a mention of it. "Contains" would
    /// mean a note discussing this feature blows itself up.
    ///
    /// The custom phrase is additive, never a replacement: settings do not sync between devices, so a
    /// phrase that replaced the built-in one would leave every device the user did not reconfigure
    /// deaf to the trigger, and a fan-out that reaches half the devices is not a fan-out.
    public static func matches(_ text: String, customPhrase: String? = nil) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty { return false }
        if candidate == builtInPhrase { return true }
        if let custom = customPhrase?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return candidate == custom
        }
        return false
    }

    /// The phrase a device broadcasts when it wipes itself by hand (PLAN.md 3.22.7).
    ///
    /// This device's own phrase: the custom one when it has one, the built-in one otherwise. It
    /// listens for both either way — the built-in phrase can never be turned off (3.22.2).
    ///
    /// This reverses the earlier rule, which broadcast the built-in phrase always so that the fan-out
    /// could not miss a device which had never been given the custom one. Two things were traded, and
    /// both are worth stating because neither is obvious:
    ///
    /// - **A device that does not know this phrase will not wipe.** The fan-out now only reaches
    ///   devices set to the same phrase, so the settings page tells the user to set the same one
    ///   everywhere. That is the user's decision to manage rather than something the code can
    ///   guarantee.
    /// - **The custom phrase stops being private the first time it is used.** A hand wipe puts it in
    ///   Saved Messages in cleartext, where 3.22.5 keeps it for thirty days. Staying private again
    ///   means choosing a new phrase.
    ///
    /// A blank stored phrase is not a phrase: broadcasting one would send an empty message that
    /// matches nothing, which is a fan-out that silently reaches nobody. Mirrors Web A
    /// `broadcastWipePhrase()` in `src/secutg/wipe/phrase.ts`.
    public static func broadcastPhrase(customPhrase: String? = nil) -> String {
        let custom = customPhrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        return builtInPhrase
    }

    /// PLAN.md 3.22.7: whether this outgoing text is a wipe phrase headed for the user's own Saved
    /// Messages, and therefore has to bypass the A1 encrypt hook and go on the wire in the clear.
    ///
    /// A device that never received the keyring (PLAN.md 3.14) cannot open an `E1:` envelope, and those
    /// are exactly the devices the trigger has to reach — an encrypted phrase would fan out to nobody
    /// but the devices that needed it least. The custom phrase is exempt too: the user typing their own
    /// sentence into Saved Messages by hand is the same trigger arriving by the same road (PLAN.md
    /// 3.22.2 explicitly supports typing it yourself, not only the button's broadcast).
    ///
    /// Stateless on purpose. The alternative — switching the self-chat's encryption flag off just before
    /// the broadcast — changes persisted state to express a decision about one message: it exempts
    /// nothing the user types themselves, and if the wipe does not finish, Saved Messages stays
    /// permanently unencrypted, against PLAN.md 3.20.
    ///
    /// Scoped to Saved Messages, and to a text that IS the phrase. It is the only chat where the phrase
    /// means anything, and this is a hole in "an encrypted chat sends ciphertext": it stays as small as
    /// it can be. Ported from Android `WipePhrase.isWipePhraseToSelf`; both sides take the chat id in
    /// their own client's numbering, which for a user chat is the bare user id either way.
    ///
    /// - Parameters:
    ///   - chatId: the chat the text is going to, as this client keys chats (`SharedChatId`).
    ///   - ownUserId: this account's user id; Saved Messages is the chat whose id equals it.
    public static func isWipePhraseToSelf(chatId: String, ownUserId: String, text: String, customPhrase: String? = nil) -> Bool {
        if ownUserId.isEmpty || ownUserId == "0" { return false }
        if chatId != ownUserId { return false }
        return matches(text, customPhrase: customPhrase)
    }

    /// Why a custom phrase the user typed was refused.
    public enum PhraseRejection: String, Equatable {
        case tooShort = "too_short"
        case sameAsBuiltIn = "same_as_built_in"
    }

    public enum PhraseValidation: Equatable {
        /// The trimmed phrase to store.
        case accepted(String)
        case rejected(PhraseRejection)
    }

    /// Checks a phrase the user typed into the settings, returning what to store or why not.
    /// Length is counted in Characters (grapheme clusters) so a phrase of Chinese characters is
    /// judged by how many the user typed, matching Web A's `.length` on a code-unit string closely
    /// enough for the "at least 12" rule while staying correct for emoji.
    public static func validateCustomPhrase(_ raw: String) -> PhraseValidation {
        let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if phrase.count < minCustomPhraseLength { return .rejected(.tooShort) }
        if phrase == builtInPhrase { return .rejected(.sameAsBuiltIn) }
        return .accepted(phrase)
    }
}
