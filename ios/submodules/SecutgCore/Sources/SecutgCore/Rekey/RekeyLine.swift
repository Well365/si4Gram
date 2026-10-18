import Foundation

/// The one rekey control line a person sees, chosen from what the message did and what they hold
/// (PLAN.md 3.32 review, batch 1). The Web original is `src/secutg/ui/rekeyLine.ts`; the five clients answer
/// alike, and each renders the key this returns through its own string table.
///
/// Two of these used to be one line. A person the admin left out of a reset and a person who has not been
/// given the key yet both got "rekey message ignored: not_addressed" — the same words for opposite
/// situations, neither of them a thing a person can act on. They part on `hasKey`: someone holding a key for
/// this chat who is not in the new key's list was left out, someone holding none was never in. Everything
/// else the processor refuses is a wire-level fault (bad signature, malformed, nobody's key) and keeps the
/// technical line, because there is nothing for the reader to do about it but tell somebody.
///
/// A `welcome` also splits: `already_known` is what every existing holder sees, and it is not news to them;
/// the newcomer, for whom it is the whole point, gets told plainly that they are in.
public enum RekeyLine {
    /// The string key to render. `SecutgRekeyRejected` is the only one that takes an argument (`{reason}`).
    ///
    /// - Parameters:
    ///   - ok: whether the processor applied the message.
    ///   - type: the R1's type; nil reads as a rotate, the same default the stored `detail` falls back to.
    ///   - reason: the processor's `reason` — `already_known` on an applied message, the refusal on a rejected one.
    ///   - hasKey: whether this device holds a key for the chat at all — what separates "left out" from "not in yet".
    /// - Returns: the string key, or nil for a row that has no sentence yet — see the `pending` case below.
    public static func key(ok: Bool, type: Rekey.R1Type?, reason: String?, hasKey: Bool) -> String? {
        if ok {
            if type == .ratchet { return "SecutgRatchetApplied" }
            if type == .welcome {
                return reason == "already_known" ? "SecutgRekeyWelcomeOther" : "SecutgRekeyWelcomeYou"
            }
            if type == .reset { return "SecutgRekeyAppliedReset" }
            return "SecutgRekeyAppliedRotate"
        }
        if reason == "not_addressed" { return hasKey ? "SecutgRekeyNotForYou" : "SecutgRekeyNoKeyYet" }
        // PLAN.md 3.34.7 item 4: parked, not refused. The message is waiting for the notice that makes its
        // signing key trusted, and it will be judged again the moment that arrives. A reason that will not last
        // is not worth a line — the same silence a parked notice gets, for the same reason.
        if reason == "pending" { return nil }
        return "SecutgRekeyRejected"
    }
}
