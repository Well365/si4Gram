import Foundation
import Postbox

// SECUTG-HOOK (PLAN.md 3.48.0 hook ⑦ / 3.48.7 §3-4): the one place "a message left the local message store, for
// any reason" is observable, because `_internal_deleteMessages` and `_internal_clearHistory` /
// `_internal_clearHistoryInRange` (`TelegramEngine/Messages/DeleteMessages.swift`) are the shared primitives
// every higher path already funnels through — interactive delete, a synced delete-for-everyone from another
// device, an auto-remove timer, a secret-chat teardown, leaving/removing a chat. Patching those two call sites
// once, instead of every call site above them, is what keeps this hook singular and the deletion flow itself
// untouched.
//
// `TelegramCore` is shared by the iOS and macOS clients (the macOS app vendors its own copy of this same
// submodule), so this file and its two call sites exist once and serve both.
//
// This hook carries no relay logic at all — SecutgCore's `RelayDeletion.plan` decides what to do; the app layer
// (TelegramUI's `SecutgRelay` component / Telegram-Mac's `Secutg/Relay`) registers the closure and is the only
// thing that imports `SecutgCore`, keeping `TelegramCore` itself unaware the relay feature exists.
//
// Contract: `onMessagesRemoved` MUST NOT throw and MUST NOT block — it fires inside an open Postbox transaction,
// so it may read the transaction it is handed but must only enqueue (never run inline) any network or
// cross-process work. The registrant is responsible for catching its own errors; this hook performs no
// try/catch of its own because a plain closure call cannot throw in the first place.
public enum SecutgRelayDeletionHook {
    public static var onMessagesRemoved: ((Transaction, [MessageId]) -> Void)?
}
