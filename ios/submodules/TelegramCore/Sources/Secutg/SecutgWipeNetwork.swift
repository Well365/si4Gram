import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import SecutgCore

/// SECUTG: the two pieces of the emergency wipe that have to talk to the server (PLAN.md 3.22).
///
/// Both deliberately go straight at `Api.functions` instead of the ordinary send / history machinery,
/// and for the same reason in each case: that machinery runs the secuTG hooks, and here the hooks are
/// exactly what must not run.
///
/// The orchestration that calls these lives in `SecutgWipe` (TelegramUI) — this file knows nothing
/// about wipe policy, only how to put one plain string on the wire and how to read Saved Messages back.
public enum SecutgWipeNetwork {
    /// Posts the **built-in** wipe phrase to this account's own Saved Messages, in **cleartext**
    /// (PLAN.md 3.22.7).
    ///
    /// Three things about this are load-bearing, and each was a bug on some port before it was a rule:
    ///
    ///  - **Cleartext.** Saved Messages encrypts itself by default since 3.20, so the normal send path
    ///    would put an `E1:` envelope on the server. Every other device would then need this device's
    ///    keyring to read the trigger — which is precisely the set of devices that do not have it — so
    ///    the fan-out would reach nobody. Going around `prepareOutgoing` is the whole point of issuing
    ///    the request here rather than through `PendingMessageManager`.
    ///  - **This device's own phrase**, which is the custom one when it has one (3.22.7, reversed on
    ///    2026-09-19). Two costs come with that and `WipePhrase.broadcastPhrase` states both: the
    ///    fan-out now only reaches devices set to the same phrase, and a custom phrase stops being
    ///    private the first time it is used, because this puts it on the server in cleartext.
    ///    `customPhrase` must be read by the caller BEFORE the keyring is destroyed — it lives in the
    ///    keyring, and step ① of the wipe takes the keyring away.
    ///  - **Never waited on.** The caller queues this and moves on; PLAN.md 3.22.8 is explicit that an
    ///    offline device still wipes itself, it just loses the ability to tell the others.
    ///
    /// `inputPeerSelf` needs no peer lookup, so this works even when the postbox is already half gone.
    public static func broadcastWipePhrase(account: Account, customPhrase: String?) -> Signal<Never, NoError> {
        // Resolved here and now, not inside the request: by the time the network gets to it the keyring
        // this phrase came from is already gone.
        let phrase = WipePhrase.broadcastPhrase(customPhrase: customPhrase)
        return account.network.request(Api.functions.messages.sendMessage(
            flags: 0,
            peer: .inputPeerSelf,
            replyTo: nil,
            message: phrase,
            randomId: Int64.random(in: Int64.min ... Int64.max),
            replyMarkup: nil,
            entities: nil,
            scheduleDate: nil,
            scheduleRepeatPeriod: nil,
            sendAs: nil,
            quickReplyShortcut: nil,
            effect: nil,
            allowPaidStars: nil,
            suggestedPost: nil,
            richMessage: nil
        ))
        |> `catch` { _ -> Signal<Api.Updates, NoError> in
            // Telling the other devices is best effort and must never hold this one up.
            return .complete()
        }
        |> ignoreValues
    }

    /// Ends every other session on this account — Telegram's own "Terminate other sessions"
    /// (`auth.resetAuthorizations`), PLAN.md 3.22.6.
    ///
    /// This and the Saved Messages phrase are complementary, not redundant: this one takes effect
    /// immediately but erases nothing, the phrase erases disks but only once the other device next
    /// reaches the server. The caller gives it a few seconds and then stops caring — an unreachable
    /// server must never keep the local traces alive (PLAN.md 3.22.8).
    ///
    /// Wrapped here because `terminateOtherAccountSessions` is internal to this module and the
    /// orchestration lives in the UI layer.
    public static func resetOtherAuthorizations(account: Account) -> Signal<Never, NoError> {
        return account.network.request(Api.functions.auth.resetAuthorizations())
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .complete()
        }
        |> ignoreValues
    }

    /// Ends **this** session on the server (`auth.logOut`), PLAN.md 3.16 step ②.
    ///
    /// Issued by hand rather than left to Telegram's own logout cleanup, because that cleanup *waits*
    /// for this request before it deletes the account directory — and an MTProto request on a device
    /// with no network waits forever. PLAN.md 3.16 is explicit that no step may block the next one, so
    /// the wipe fires this best-effort, gives it the same few seconds as everything else, and then
    /// removes the local data itself regardless of how it went.
    public static func logOutThisSession(account: Account) -> Signal<Never, NoError> {
        return account.network.request(Api.functions.auth.logOut())
        |> `catch` { _ -> Signal<Api.auth.LoggedOut, NoError> in
            return .complete()
        }
        |> ignoreValues
    }

    /// How much Saved Messages history one scan pass reads. Comfortably more than thirty days of an
    /// ordinary Saved Messages, in a single request (mirrors Web `wipeScan.ts` `SCAN_LIMIT`).
    public static let scanLimit: Int32 = 200

    /// Reads recent Saved Messages from the **server** for the wipe scan (PLAN.md 3.22.3).
    ///
    /// Server rather than postbox on purpose: the scan that matters runs a minute after login, and at
    /// that moment the local database may hold nothing at all — the sixty seconds in 3.22.4 buy the
    /// initial sync time, they do not guarantee it finished.
    ///
    /// Each message yields up to two candidates, which is 3.22.3 rule 2 ("compare both texts"): the raw
    /// wire text, which is what an official client posts, and — when this device can open it — the
    /// plaintext behind an `E1:` envelope posted by another secuTG device. They share a message id, so
    /// the already-consumed check and the newest-first ordering both still behave.
    public static func fetchSavedMessagesForWipeScan(account: Account) -> Signal<[WipeScan.Candidate], NoError> {
        let accountPeerId = account.peerId
        return account.network.request(Api.functions.messages.getHistory(
            peer: .inputPeerSelf, offsetId: 0, offsetDate: 0, addOffset: 0,
            limit: scanLimit, maxId: 0, minId: 0, hash: 0
        ))
        |> map { result -> [WipeScan.Candidate] in
            return candidates(from: apiMessages(result), accountPeerId: accountPeerId)
        }
        |> `catch` { _ -> Signal<[WipeScan.Candidate], NoError> in
            // A failed pass is not an error anybody can act on; the next one tries again.
            return .single([])
        }
    }

    private static func apiMessages(_ result: Api.messages.Messages) -> [Api.Message] {
        switch result {
        case let .messages(data): return data.messages
        case let .messagesSlice(data): return data.messages
        case let .channelMessages(data): return data.messages
        case .messagesNotModified: return []
        }
    }

    private static func candidates(from messages: [Api.Message], accountPeerId: PeerId) -> [WipeScan.Candidate] {
        let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId)
        var result: [WipeScan.Candidate] = []
        for message in messages {
            guard case let .message(data) = message, !data.message.isEmpty else { continue }
            result.append(WipeScan.Candidate(id: Int64(data.id), text: data.message, date: Int64(data.date)))
            guard E1Format.isEncrypted(data.message), let runtime = runtime,
                  case let .opened(text, _) = runtime.openSealed(wire: data.message), !text.isEmpty else { continue }
            result.append(WipeScan.Candidate(id: Int64(data.id), text: text, date: Int64(data.date)))
        }
        return result
    }
}
