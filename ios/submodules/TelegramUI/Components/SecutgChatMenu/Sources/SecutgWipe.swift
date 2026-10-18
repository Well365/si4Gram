import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SecutgCore
import SecutgRelay // SECUTG-HOOK (PLAN.md 3.48.0 hook ⑤ / 3.48.7 §5)

/// SECUTG: the emergency wipe, orchestrated (PLAN.md 3.16 / 3.22).
///
/// `SecutgAccountRuntime` owns the one step that is instant, local and cannot fail — destroying the
/// keys. Everything around it needs the account, the network and the logout machinery, which is why it
/// lives up here. The order is the specification's, and the order is the whole design:
///
///   ⓪ queue the plaintext phrase to Saved Messages, and **do not wait for it**
///   ① destroy every key on this device, right now
///   ② give the network about three seconds to end the other sessions and this one
///   ③ whatever happened to ②, delete the local data and sign out
///
/// An emergency button whose value is that it works when nothing else does may not wait on a socket.
/// Step ① is therefore ahead of every network call, and step ③ is not conditional on step ②.
public enum SecutgWipe {
    /// The grace the network gets before the local data goes anyway (PLAN.md 3.22.8, "about 3 seconds").
    public static let networkGraceSeconds: Double = 3.0

    /// The first scan waits this long after login so the initial sync has pulled Saved Messages down
    /// (PLAN.md 3.22.4). `WipePhrase.scanDelayMs` is the shared constant; this is it in seconds.
    public static var firstScanDelaySeconds: Double { return Double(WipePhrase.scanDelayMs) / 1000.0 }

    /// The backstop re-scan for a session that is already running (PLAN.md 3.22.4). The scan that
    /// matters is the one after login: a device that is online when another device fires the wipe is
    /// knocked off by that device's `auth.resetAuthorizations` and comes back through the login path.
    public static let rescanSeconds: Double = 5 * 60

    // MARK: - Running the wipe

    /// Runs the full wipe. `isRemote` is true when a phrase in Saved Messages triggered it rather than
    /// the user's own tap, and it gates the two things that would otherwise echo around the account
    /// forever: a remotely-triggered device neither re-broadcasts the phrase nor ends anybody's
    /// sessions (PLAN.md 3.22.4).
    public static func run(context: AccountContext, isRemote: Bool) {
        let account = context.account
        let accountId = account.id
        let accountManager = context.sharedContext.accountManager
        let runtime = SecutgHookRegistry.shared.runtime(for: account.peerId)

        // What this wipe does besides destroying the keys. The rules live in `SecutgCore.WipePlan`,
        // under test, because the gating is the part of 3.22 that two other ports each got wrong on
        // their own — in particular, the broadcast is gated on `isRemote` ALONE and never on
        // `wipeListensToPhrase`; see `WipePlan.make` for why those are different questions.
        let plan = WipePlan.make(isRemote: isRemote,
                                 listensToPhrase: runtime?.wipeListensToPhrase ?? true,
                                 resetsAuthorizations: runtime?.wipeResetsAuthorizations ?? true)

        // ⓪ Fan-out, queued and never awaited (PLAN.md 3.22.7 / 3.22.8). What goes out is THIS device's
        // own phrase — the custom one when it has one (reversed on 2026-09-19) — and it goes out in
        // cleartext so that devices which never had this keyring can still read it.
        //
        // The phrase is read here, above step ①, because it lives in the keyring that step ① destroys.
        if plan.broadcastsPhrase {
            let _ = SecutgWipeNetwork.broadcastWipePhrase(account: account,
                                                          customPhrase: runtime?.wipeCustomPhrase).start()
        }

        // ① The keys, immediately. Synchronous, local, cannot fail. Everything below may fail freely.
        runtime?.destroyKeyring()

        // A wiped device has no memory of who it once decided about (PLAN.md 3.23.3), nor of which
        // chats it was once asked to encrypt (PLAN.md 3.24.8), nor of how it was asked to draw the
        // messages it could not read (PLAN.md 3.17 rule 5). The consumed marker is deliberately
        // NOT touched here — it is the single survivor of the purge, and without it this account
        // wipes itself a minute after every login for thirty days (3.22.5).
        SecutgLocalPrefs.clearStrangerDecisions(accountKey: accountKey(account))
        SecutgLocalPrefs.clearOnboardMemories(accountKey: accountKey(account))
        SecutgLocalPrefs.clearFoldPreference(accountKey: accountKey(account))
        // PLAN.md 3.46: the check-up's ignore list, group-key limit and backup time go too; PLAN.md 3.40.6: so does
        // this device's own API credentials setting (the next start shows the gate again).
        SecutgLocalPrefs.clearAuditPrefs(accountKey: accountKey(account))
        // PLAN.md 3.46.1: the record of chats this device showed a code for; PLAN.md 3.47: the catch-up watermarks.
        SecutgLocalPrefs.clearLostDeviceShownCodes(accountKey: accountKey(account))
        SecutgLocalPrefs.clearCatchUpWatermarks(accountKey: accountKey(account))
        SecutgApiCredentialsUI.clearForWipe()
        // SECUTG-HOOK (PLAN.md 3.48.0 hook ⑤ / 3.48.5 / 3.48.7 §5): app-level relay config (settings, my relays,
        // trust list) and this account's relay sent-items / local copies — independent store, independent wipe,
        // never touched by anything above. A no-op when the feature was never used (nothing was ever written).
        SecutgRelayRuntime.shared.wipeForEmergencyWipe(context: context)

        // ② Network, best effort, time-boxed.
        var remote: [Signal<Never, NoError>] = []
        if plan.resetsAuthorizations {
            // Instant where the phrase is eventual: this locks the other devices out now, the phrase
            // destroys what is on their disks whenever they next reach the server (PLAN.md 3.22.6).
            remote.append(SecutgWipeNetwork.resetOtherAuthorizations(account: account))
        }
        remote.append(SecutgWipeNetwork.logOutThisSession(account: account))

        let networkSide = combineLatest(remote.map(settled))
        |> map { _ -> Void in }
        // Whichever finishes first wins; the alternate is what makes "the server never answered" a
        // normal outcome rather than a hang.
        |> timeout(networkGraceSeconds, queue: Queue.mainQueue(), alternate: Signal<Void, NoError>.single(Void()))

        let _ = (networkSide |> take(1) |> deliverOnMainQueue).start(next: { _ in
            purgeAndSignOut(accountId: accountId, accountManager: accountManager)
        })
    }

    /// "Finished, one way or the other." Every signal here is already `catch`-ed to completion, so a
    /// refused or unreachable request completes rather than erroring; this turns completion into the
    /// single value `combineLatest` needs in order to fire at all.
    private static func settled(_ signal: Signal<Never, NoError>) -> Signal<Void, NoError> {
        return Signal { subscriber in
            return signal.start(completed: {
                subscriber.putNext(Void())
                subscriber.putCompletion()
            })
        }
    }

    /// ③ The local data and the session (PLAN.md 3.16 step ③).
    ///
    /// `alreadyLoggedOutRemotely: true` is not a claim that the server agreed — step ② already sent
    /// `auth.logOut` itself and did not care whether it arrived. It is what makes the account record
    /// vanish *now* instead of after a round trip: passing `false` hands the record to Telegram's own
    /// cleanup, which will not delete a single byte until its own `auth.logOut` returns, so an offline
    /// device would sit there with every cached message still on disk. The record going away is what
    /// makes `managedCleanupAccounts` sweep the account directory — postbox, media, avatars, state.
    private static func purgeAndSignOut(accountId: AccountRecordId, accountManager: AccountManager<TelegramAccountManagerTypes>) {
        let _ = logoutFromAccount(id: accountId, accountManager: accountManager, alreadyLoggedOutRemotely: true).start()
    }

    /// Keys the UserDefaults entries per account, so a multi-account device keeps them apart.
    private static func accountKey(_ account: Account) -> String {
        return SecutgLocalPrefs.accountKey(account.peerId)
    }

    // MARK: - Saved Messages watch (PLAN.md 3.22.4)

    /// Which accounts already have a watch running. Main queue only — every mutation below is either in
    /// `AuthorizedApplicationContext.init` or inside a main-queue timer.
    private static var watchedAccounts = Set<Int64>()

    /// Starts this account's Saved Messages watch, once. Idempotent, so it is safe on every launch.
    public static func startPhraseWatch(context: AccountContext) {
        let key = context.account.peerId.toInt64()
        if watchedAccounts.contains(key) { return }
        watchedAccounts.insert(key)
        schedule(context: context, key: key, after: firstScanDelaySeconds)
    }

    private static func schedule(context: AccountContext, key: Int64, after delay: Double) {
        Queue.mainQueue().after(delay) { [weak context] in
            // The context is gone: this account was signed out (very possibly by a wipe). Forget that
            // it was watched, or logging back in would find the flag still set, skip arming a watch,
            // and leave the device deaf to the phrase for the rest of the process's life.
            guard let context = context else {
                watchedAccounts.remove(key)
                return
            }
            scanOnce(context: context, completion: { didWipe in
                // A wipe ends with the account signed out; there is nothing left to re-scan. The flag
                // is dropped so a fresh login re-arms from the sixty-second first pass.
                if didWipe {
                    watchedAccounts.remove(key)
                } else {
                    schedule(context: context, key: key, after: rescanSeconds)
                }
            })
        }
    }

    /// One pass. Never throws, never blocks the caller.
    private static func scanOnce(context: AccountContext, completion: @escaping (Bool) -> Void) {
        let account = context.account
        guard let runtime = SecutgHookRegistry.shared.runtime(for: account.peerId), runtime.wipeListensToPhrase else {
            completion(false)
            return
        }
        let key = accountKey(account)
        let userId = runtime.ownUserId

        let _ = (SecutgWipeNetwork.fetchSavedMessagesForWipeScan(account: account) |> deliverOnMainQueue).start(next: { candidates in
            let consumed = SecutgLocalPrefs.readConsumed(accountKey: key)
            guard let found = runtime.findWipeTrigger(in: candidates,
                                                     nowSeconds: Int64(Date().timeIntervalSince1970),
                                                     consumed: consumed) else {
                completion(false)
                return
            }

            // Written BEFORE the wipe, never after. The wipe ends in a sign-out; a marker that never
            // got written sends this device round the same loop a minute after the next login, for
            // the thirty days the phrase stays in Saved Messages (PLAN.md 3.22.5).
            SecutgLocalPrefs.writeConsumed(
                WipeScan.Consumed(userId: userId, messageId: found.id, triggerDate: found.date,
                                  executedAt: Int64(Date().timeIntervalSince1970 * 1000)),
                accountKey: key)

            // No confirmation: a remotely-triggered wipe that stops to ask has missed the point.
            run(context: context, isRemote: true)
            completion(true)
        })
    }
}
