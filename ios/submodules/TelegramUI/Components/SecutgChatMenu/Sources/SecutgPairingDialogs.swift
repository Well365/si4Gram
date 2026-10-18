import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import LocalizedPeerData
import SecutgCore

/// SECUTG: the one-to-one pairing dialogs of PLAN.md 3.7.1, driven by `SecutgAccountRuntime.pairingEvents`
/// (the same rules as Web A `notifyPairing` / `apiUpdaters/secutg.ts`). The chat controller observes the
/// events of the chat it shows; a fresh invite pops "{name} invites you…" and a completed pairing pops the
/// safety code.
///
/// The encrypted confirmation text of rule 10 is deliberately *not* part of that: it is posted by
/// `installConfirmationSender`, an account-wide listener with no controller in it at all. See there for why.
public enum SecutgPairingDialogs {
    private static var observedPeerIds: [PeerId: Int] = [:]
    /// One live confirmation sender per account (`installConfirmationSender`). Main queue only.
    private static var confirmationSenders: [PeerId: Disposable] = [:]
    /// One live v2 pairing wire relay per account (`installPairingWireSender`). Main queue only.
    private static var pairingWireSenders: [PeerId: Disposable] = [:]

    // MARK: the encrypted confirmation message (PLAN.md 3.7.1 rule 10)

    /// Installs this account's sender for the "🔒 加密已开启" message, for the lifetime of the account.
    ///
    /// **Why this is not in the dialog.** Until this existed, the confirmation was sent from inside
    /// `presentDone`, i.e. from the dialog — and the dialog is only reachable through `observe`, which only
    /// runs while a `ChatController` for that exact chat is on screen. So the message that tells both people
    /// "everything from here on is encrypted" went out only when the pairing happened to complete *while the
    /// user was looking at that chat*. Pair from the chat list, from another chat, or with the app in the
    /// background, and it was never sent at all — and the catch-up path could not rescue it either, because a
    /// replay must not re-post a real message (`PairConfirmation`).
    ///
    /// Web A has never had this problem: it posts the text from the global `apiUpdate` handler
    /// (`global/actions/apiUpdaters/secutg.ts`), which knows nothing about which chat is open. macOS posts it
    /// from `secutgObservePairing`, above that file's `globalLocationId` gate, for the same reason. This is the
    /// iOS shape of the same rule, and the call site is `AccountContextImpl.init` — one per account, created
    /// before `resetStateManagement()` starts feeding this account any messages, so the listener is attached
    /// before the first `P1` can possibly be processed.
    ///
    /// **Why it still goes out exactly once per pairing.** Three things together, none of them a counter:
    ///  1. the runtime raises `shouldConfirm == true` on exactly one event, in exactly one place — the
    ///     `.paired` branch of `notifyPairing`, i.e. the moment the peer's `P1` completes the pairing *here*;
    ///  2. `PairConfirmation.shouldSend` (SecutgCore, under test) is the only gate, so the inviting side's own
    ///     locally-completed `.done` and every `PairingDialogCatchUp` replay — both `shouldConfirm == false` —
    ///     are silent by construction rather than by remembering to pass a flag;
    ///  3. there is one subscriber per account, replaced rather than added to below, and `pairingEvents` is a
    ///     `ValuePipe` with no replay, so the one event reaches exactly one sender exactly once.
    ///
    /// Idempotent per account, and re-installing after a sign-out / sign-in swaps in the new context instead
    /// of leaving a sender bound to the dead one. Main queue only.
    public static func installConfirmationSender(context: AccountContext) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let accountPeerId = context.account.peerId
        confirmationSenders.removeValue(forKey: accountPeerId)?.dispose()
        confirmationSenders[accountPeerId] = (runtime.pairingEvents.signal() |> deliverOnMainQueue).start(next: { [weak context] event in
            guard let context else { return }
            guard PairConfirmation.shouldSend(isPairingDone: event.phase == .done, completedHere: event.shouldConfirm) else { return }
            SecutgChatMenu.syncLanguage(context: context)
            // Rule 10: one ordinary text message; the A1 hook encrypts it like any other text in the chat.
            SecutgChatMenu.sendText(context: context, peerId: event.chatPeerId, text: SecutgL10n.string("SecutgPairConfirmMessage"))
        })
    }

    // MARK: the v2 pairing auto-relay (SECUTG-HOOK, fix)

    /// Installs this account's relay for `SecutgAccountRuntime.v2PairingWires`, for the lifetime of the
    /// account. Idempotent, same reason as `installConfirmationSender`.
    ///
    /// SECUTG-HOOK (fix): `v2PairingWires` was added in the UI-01 round (PLAN.md) with a doc comment
    /// explicitly noting nothing subscribed to it yet, and that this was safe only because no real
    /// `V2Runtime` existed for any account at the time. Real-startup bootstrap later made that
    /// precondition false — every real account now has a `V2Runtime` computing SELECT/CONFIRM/READY
    /// wires and pushing them here — but nobody added the subscriber this pipe's own doc said it would
    /// need. Every wire pushed here was silently discarded: ACCEPT itself sends fine (a different code
    /// path, `startPairingV2`'s own return value), but the fully-automatic SELECT→CONFIRM→READY relay
    /// that should follow with no user action never fired, so pairing could stall right after the user
    /// tapped accept — even with both sides online the whole time.
    public static func installPairingWireSender(context: AccountContext) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let accountPeerId = context.account.peerId
        pairingWireSenders.removeValue(forKey: accountPeerId)?.dispose()
        pairingWireSenders[accountPeerId] = (runtime.v2PairingWires.signal() |> deliverOnMainQueue).start(next: { [weak context] chatAndWire in
            guard let context else { return }
            SecutgChatMenu.sendText(context: context, peerId: chatAndWire.0, text: chatAndWire.1)
        })
        // PLAN.md 3.39.13: the 3.39.3 step 6 expiry sweeper is gone with the add_device share — a clone code leaves
        // nothing behind on the showing device to expire.
    }

    // MARK: the dialogs

    /// Subscribes the visible chat to its pairing events; dispose when the chat leaves the screen.
    public static func observe(context: AccountContext, peerId: PeerId, controller: ViewController) -> Disposable {
        guard peerId.namespace == Namespaces.Peer.CloudUser, let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else {
            return EmptyDisposable
        }
        observedPeerIds[peerId, default: 0] += 1
        // PLAN.md 3.7.1 catch-up: `pairingEvents` only reaches a listener subscribed at the exact instant
        // it fires. A pairing that completed while no controller for this chat was on screen — and every
        // controller opened afterwards, since each fresh instance only hears *future* events — would
        // otherwise never show the "配对完成" dialog at all. Checking this every time the chat is observed,
        // independent of the live signal below, is what lets a later visit still catch a pairing this
        // device missed.
        checkPairingDialogCatchUp(context: context, peerId: peerId, controller: controller, runtime: runtime)
        let events = (runtime.pairingEvents.signal() |> deliverOnMainQueue).start(next: { [weak controller] event in
            guard event.chatPeerId == peerId, let controller else { return }
            SecutgChatMenu.syncLanguage(context: context)
            switch event.phase {
            case .invite:
                // SECUTG-HOOK: this phase used to fire for two reasons — a genuine v1 P1 or a genuine
                // v2 P2 INVITE (`SecutgAccountRuntime.handleP2`'s own `.invited` outcome, which reuses
                // this same `notifyPairing(outcome: .incoming, ...)` call, hence the same `.invite`
                // event here) — and a prior round mistakenly deleted `presentInvite` on the theory that
                // this dialog was v1-only UI. It was not: under this controlled rollout (every device
                // that could pair is on a v2-carrying build, so v1 no longer initiates fresh pairings),
                // any invite reaching this point is effectively always v2's, and this popup is v2's own
                // "someone wants to pair with you" discoverability alert — the proactive nudge, on top
                // of `hasIncomingInvite` already surfacing the chat menu's "accept" entry passively for
                // whoever opens the menu without having seen this. Restored.
                presentInvite(context: context, peerId: peerId, controller: controller)
            case .done:
                // The confirmation message is not sent from here — `installConfirmationSender` owns it, so that
                // it goes out whether or not this chat (or any chat) happens to be on screen.
                presentDone(context: context, peerId: peerId, controller: controller, code: event.code ?? "")
            }
        })
        return ActionDisposable {
            events.dispose()
            Queue.mainQueue().async {
                let left = (observedPeerIds[peerId] ?? 1) - 1
                observedPeerIds[peerId] = left > 0 ? left : nil
            }
        }
    }

    /// The pure decision lives in `PairingDialogCatchUp` (SecutgCore): is this chat currently paired, and
    /// has this device already shown the dialog for *this* pairing episode (keyed by `pairedAt`, from
    /// `SecutgLocalPrefs`)? When it says yes, this replays the dialog exactly as the live path above would.
    /// A replay is only ever a dialog: the encrypted confirmation text was already sent once by whichever
    /// device actually completed the pairing, and re-posting a real message is not something a replay can
    /// take back — which is why `presentDone` no longer sends anything at all (`PairConfirmation`).
    /// `presentDone` itself records the new `pairedAt` as seen, so this call site cannot forget to mark it.
    private static func checkPairingDialogCatchUp(context: AccountContext, peerId: PeerId, controller: ViewController, runtime: SecutgAccountRuntime) {
        let status = runtime.status(chatPeerId: peerId)
        let accountKey = SecutgLocalPrefs.accountKey(context.account.peerId)
        let chatId = "\(peerId.toInt64())"
        let lastSeen = SecutgLocalPrefs.lastSeenPairingDialog(accountKey: accountKey, chatId: chatId)
        guard PairingDialogCatchUp.isDue(
            pairingState: status.pairingState, pairedAt: status.pairedAt,
            lastSeenPairedAt: lastSeen, isVerified: status.pairingVerified) else { return }
        SecutgChatMenu.syncLanguage(context: context)
        presentDone(context: context, peerId: peerId, controller: controller, code: runtime.safetyCode(chatPeerId: peerId) ?? "")
    }

    /// Whether some chat controller currently shows the pairing dialogs of this chat (main thread).
    public static func isObserving(peerId: PeerId) -> Bool {
        return (observedPeerIds[peerId] ?? 0) > 0
    }

    /// "{name} invites you to start an encrypted chat" — Accept sends this device's P1, Not now just closes.
    ///
    /// Restored after a prior round deleted it on the mistaken premise that it was v1-only UI: the `.invite`
    /// event driving it also fires for `SecutgAccountRuntime.handleP2`'s own v2 `.invited` outcome (same
    /// `notifyPairing(outcome: .incoming, ...)` call underneath both protocols), so removing this dialog had
    /// silenced the proactive alert for genuine, everyday v2 invites too — not just for the now-defunct v1
    /// case. Under this controlled rollout (every device that could pair is on a v2-carrying build, so v1 no
    /// longer initiates fresh pairings), an invite reaching this point is effectively always v2's; this is
    /// v2's own "someone wants to pair with you" discoverability alert now, layered on top of
    /// `hasIncomingInvite` passively surfacing the chat menu's "accept" entry for whoever opens the menu
    /// without having seen this popup.
    public static func presentInvite(context: AccountContext, peerId: PeerId, controller: ViewController) {
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)) |> deliverOnMainQueue).start(next: { [weak controller] peer in
            guard let controller else { return }
            let presentation = context.sharedContext.currentPresentationData.with { $0 }
            let name = peer?.displayTitle(strings: presentation.strings, displayOrder: presentation.nameDisplayOrder) ?? ""
            let alert = UIAlertController(title: SecutgL10n.string("SecutgPairDialogTitle", ["name": name]), message: SecutgL10n.string("SecutgPairDialogBody"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgAccept"), style: .default, handler: { [weak controller] _ in
                guard let controller else { return }
                SecutgChatMenu.startPairing(context: context, peerId: peerId, controller: controller)
            }))
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgLater"), style: .cancel))
            SecutgChatMenu.presentSystem(alert, over: controller)
        })
    }

    /// "Paired. This chat is now encrypted" with the safety code: They match → verified, Verify later, They don't match → unpair.
    ///
    /// Shows things and nothing else. Every path into it can run more than once for one pairing episode (the
    /// live event, the catch-up replay, the two menu entries), so it must have no side effect that cannot be
    /// shown twice — the encrypted confirmation text lives in `installConfirmationSender` for exactly that reason.
    public static func presentDone(context: AccountContext, peerId: PeerId, controller: ViewController, code: String) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        // PLAN.md 3.25.5 item 2: the device codes ride along under the safety code, with the standing
        // disclaimer that they are not a substitute for actually comparing the safety code above them.
        var message = SecutgL10n.string("SecutgPairDoneBody", ["code": code])
        let status = runtime.status(chatPeerId: peerId)
        // PLAN.md 3.7.1 catch-up: record this pairing episode as shown here, unconditionally, so neither
        // the live-event caller nor the catch-up check in `observe` can reach this dialog without marking
        // it — a later re-pairing produces a new `pairedAt` and is due again on its own.
        if let pairedAt = status.pairedAt {
            SecutgLocalPrefs.setSeenPairingDialog(pairedAt, accountKey: SecutgLocalPrefs.accountKey(context.account.peerId), chatId: "\(peerId.toInt64())")
        }
        var labelOptions: [(deviceId: String, title: String)] = []
        if let own = runtime.ownDeviceIdentity(), let peerDeviceId = status.peerDeviceId {
            message += "\n\n" + SecutgL10n.string("SecutgSafetyDeviceCodes", [
                "own": runtime.deviceDisplayText(own.deviceId), "peer": runtime.deviceDisplayText(peerDeviceId),
            ]) + "\n" + SecutgL10n.string("SecutgSafetyDeviceCodeNote")
            // Each picker row names its role (the same keys the status rows use): two devices nobody has
            // labelled yet are two six-character codes, and an unlabelled picker is how the wrong one gets named.
            labelOptions = [
                (peerDeviceId, SecutgL10n.string("SecutgStatusPeerDevice", ["device": runtime.deviceDisplayText(peerDeviceId)])),
                (own.deviceId, SecutgL10n.string("SecutgStatusOwnDevice", ["device": runtime.deviceDisplayText(own.deviceId)])),
            ]
        }
        let alert = UIAlertController(title: SecutgL10n.string("SecutgPairDoneTitle"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgSafetyMatch"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            runtime.setPairingVerified(chatPeerId: peerId, verified: true)
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgMarkedVerified"))
        }))
        if !labelOptions.isEmpty {
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgDeviceLabelEdit"), style: .default, handler: { [weak controller] _ in
                guard let controller else { return }
                SecutgDeviceLabelDialogs.presentPicker(context: context, controller: controller, options: labelOptions)
            }))
        }
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgSafetyLater"), style: .cancel, handler: { [weak controller] _ in
            guard let controller else { return }
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgSafetyLaterHint"))
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgSafetyMismatch"), style: .destructive, handler: { [weak controller] _ in
            guard let controller else { return }
            presentMismatch(context: context, peerId: peerId, controller: controller)
        }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    /// "Safety codes don't match": the only way out is to unpair and pair manually with an offline QR code.
    public static func presentMismatch(context: AccountContext, peerId: PeerId, controller: ViewController) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let alert = UIAlertController(title: SecutgL10n.string("SecutgSafetyMismatchTitle"), message: SecutgL10n.string("SecutgSafetyMismatchBody"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgMenuUnpair"), style: .destructive, handler: { [weak controller] _ in
            guard let controller else { return }
            // PLAN.md 3.31.3: the same one road out as the lock menu's entry — unpair here, then tell the peer
            // to destroy their copy too. Best-effort and after the fact; see `SecutgChatMenu.unpairAndNotify`.
            SecutgChatMenu.unpairAndNotify(context: context, peerId: peerId, runtime: runtime)
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgUnpaired"))
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }
}
