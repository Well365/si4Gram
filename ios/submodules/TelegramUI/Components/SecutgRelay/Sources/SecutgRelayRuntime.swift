import Foundation
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// The relay feature's own runtime glue (PLAN.md 3.48.0 rule 1/5): app-level config plus one
/// `RelayAccountState` per Telegram account, each backed by its own Keychain-sealed file — never the
/// keyring's, never v2's. Nothing outside `SecutgRelay` reads or writes these; every hook point below calls
/// into this type and nothing else.
///
/// This lives in the UI component (rather than inside `TelegramCore/Sources/Secutg`) specifically so the
/// relay feature's only footprint on `TelegramCore` is the one deletion hook (`SecutgRelayDeletionHook`,
/// PLAN.md 3.48.7 §6) — everything else about "where relay state lives and how it is wiped" is addable and
/// removable by deleting this component, per PLAN.md 3.48.0's independence rule.
public final class SecutgRelayRuntime {
    public static let shared = SecutgRelayRuntime()

    private let lock = NSLock()
    private var accountStates: [Int64: RelayAccountState] = [:]
    private var installedDeletionHook = false

    /// PLAN.md review HIGH-1: every store write (Keychain + encrypted file I/O) and network revoke the
    /// deletion hook triggers runs here, never on the Postbox transaction thread that fired the hook. One
    /// dedicated serial queue (not `.global()`) keeps this component's own writes to a given account's store
    /// ordered relative to each other without adding any lock of its own.
    private let deletionQueue = DispatchQueue(label: "org.secutg.relay.deletion", qos: .utility)

    public lazy var appState: RelayAppState = RelayAppState(store: RelayKeychainAppStore(basePath: SecutgRelayRuntime.appSupportBasePath()))
    public lazy var client: RelayClient = RelayClient()

    private init() {}

    /// One state per account, keyed the same way `SecutgHookRegistry`/`V2KeychainStorage` key their own
    /// per-account stores: the account's own `basePath` (its Application Support subdirectory) and its
    /// record id as the Keychain account name, so a relay wipe can never cross into another account's data.
    public func accountState(context: AccountContext) -> RelayAccountState {
        installDeletionHookIfNeeded()
        let key = context.account.peerId.toInt64()
        lock.lock(); defer { lock.unlock() }
        if let existing = accountStates[key] { return existing }
        let accountRecordId = "\(context.account.id.int64)"
        let store = RelayKeychainAccountStore(accountKey: accountRecordId, basePath: context.account.basePath)
        let state = RelayAccountState(store: store)
        accountStates[key] = state
        return state
    }

    /// The single key format every call site in this component uses for `RelayAccountState`'s `chatId:
    /// String` — never Postbox's own peer-id formatting, so a future change there cannot silently stop
    /// matching records this component already wrote.
    public static func chatKey(_ peerId: PeerId) -> String {
        return "\(peerId.toInt64())"
    }

    private static func appSupportBasePath() -> String {
        let paths = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
        return paths.first ?? NSTemporaryDirectory()
    }

    // MARK: - Wipe (PLAN.md 3.16 / 3.46.2 / 3.48.5 / 3.48.7 §5)

    /// 3.16 emergency wipe: app-level config AND this account's sent items / local copies.
    public func wipeForEmergencyWipe(context: AccountContext) {
        appState.wipeForEmergencyWipe()
        accountState(context: context).wipeAll()
    }

    /// 3.46.2 forced-logout wipe: this account's slice only — app-level relay config (other accounts' relays,
    /// trust list) is untouched, exactly like the keyring wipe this call sits beside.
    public func wipeForForcedLogout(context: AccountContext) {
        accountState(context: context).wipeAll()
    }

    // MARK: - Deletion hook (PLAN.md 3.48.0 hook ⑦ / 3.48.7 §3-4)

    /// Installed once, lazily, the first time anything in this component touches an account — never from
    /// `ApplicationContext` or any other existing file, so this hook point stays entirely inside the new
    /// component. Registering the closure itself does nothing observable: it only ever runs for a message
    /// whose text is an `L1:` reference, and reading an account that never used the relay finds nothing to
    /// act on (PLAN.md 3.48.0 rule 3).
    private func installDeletionHookIfNeeded() {
        lock.lock()
        guard !installedDeletionHook else { lock.unlock(); return }
        installedDeletionHook = true
        lock.unlock()
        SecutgRelayDeletionHook.onMessagesRemoved = { [weak self] transaction, ids in
            guard let self else { return }
            // PLAN.md review HIGH-1 / `SecutgRelayDeletionHook`'s own contract: this closure runs inside an
            // open Postbox transaction and MUST NOT block or do I/O. Everything below this point reads only
            // the transaction (already open, no extra cost) and each account's in-memory snapshot (an NSLock
            // + dictionary lookup — no disk, no Keychain) to work out a cheap, immutable plan per message. The
            // actual store writes and the network revoke are collected into `work` and handed to
            // `deletionQueue` once, after this closure returns and the transaction is free to close; nothing
            // here captures `transaction` for later use.
            var work: [DeletionWorkItem] = []
            for id in ids {
                // Deliberately does not decrypt a paired chat's `E1:`/`E2:` envelope here: by the time a message
                // is actually deleted its envelope's plaintext is no longer obtainable by this hook (the keyring
                // may already be gone on a wipe), so this only ever matches a relay message whose stored text is
                // itself `L1:` — the unpaired-chat case and the plaintext-cache-miss case. The paired-chat case is
                // covered differently: the local copy and sent-item record are looked up by (chat, message id)
                // regardless of what the now-deleted row's text says, so a plan that finds nothing here still lets
                // `removeLocalCopy`/`markRevoked` below run as harmless no-ops against those keyed records.
                guard let message = transaction.getMessage(id) else { continue }
                let chatKey = SecutgRelayRuntime.chatKey(id.peerId)
                let messageId = id.id.toInt64Message()
                let text = message.text
                for state in self.snapshotAccountStates() {
                    let sentItem = state.sentItem(chatId: chatKey, messageId: messageId)
                    let plan = RelayDeletion.plan(text: text, sentItem: sentItem)
                    guard plan.removeLocalCopy || plan.revoke != nil else { continue }
                    work.append(DeletionWorkItem(state: state, chatKey: chatKey, messageId: messageId, plan: plan))
                }
            }
            guard !work.isEmpty else { return }
            self.deletionQueue.async { [weak self] in
                self?.applyDeletionWork(work)
            }
        }
    }

    /// One message's worth of deferred relay-deletion work (PLAN.md 3.48.7 §3-4), computed with no I/O while
    /// the Postbox transaction was still open; applied later, off that thread, by `applyDeletionWork`.
    private struct DeletionWorkItem {
        let state: RelayAccountState
        let chatKey: String
        let messageId: Int64
        let plan: RelayDeletionPlan
    }

    /// Runs exclusively on `deletionQueue`: the Keychain + encrypted file I/O (`RelayAccountState`'s store
    /// writes) and the network revoke, none of which may happen on the Postbox transaction thread that
    /// discovered them. Semantics are unchanged from before this queue existed — local copy removed, sender
    /// revoke attempted and retried on failure — only the thread and timing moved.
    private func applyDeletionWork(_ work: [DeletionWorkItem]) {
        for item in work {
            if item.plan.removeLocalCopy {
                item.state.removeLocalCopy(chatId: item.chatKey, messageId: item.messageId)
            }
            if let revoke = item.plan.revoke {
                item.state.markRevoked(id: revoke.itemId)
                client.delete(baseURL: revoke.relayURL, id: revoke.itemId, deleteToken: revoke.deleteToken) { [weak self] result in
                    if case .failure = result {
                        // PLAN.md 3.48.7 §4: failure is recorded, retryable from the sent-items list, never
                        // blocks the deletion that already happened. Hopped back onto `deletionQueue` so this
                        // write, too, never lands on whatever thread URLSession calls the completion on.
                        self?.deletionQueue.async {
                            item.state.markRevoked(id: revoke.itemId, pendingRetry: true)
                        }
                    }
                }
            }
        }
    }

    private func snapshotAccountStates() -> [RelayAccountState] {
        lock.lock(); defer { lock.unlock() }
        return Array(accountStates.values)
    }
}

extension Int32 {
    /// `MessageId.Id` is `Int32`; the relay store keys sent items/local copies by `Int64` so the same
    /// representation works across a future namespace change without widening every call site today.
    fileprivate func toInt64Message() -> Int64 { return Int64(self) }
}
