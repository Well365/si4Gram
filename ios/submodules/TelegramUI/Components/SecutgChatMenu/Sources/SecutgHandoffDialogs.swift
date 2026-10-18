import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import AccountContext

/// SECUTG (PLAN.md 3.25.5 item 3 / 3.25.6): when this device is not the one holding a private chat's pairing
/// (`other_device`), this is where the user is told so, with the device that does hold it named, and offered
/// "在本机接管". PLAN.md 3.23's "陌生人来信" block — the precedent this section says to reuse the mounting
/// point of — is pure logic only on this client so far (`StrangerNotice` in SecutgCore, with no scrolling
/// message-stream banner built for it yet), so this instead reuses the mechanism `SecutgPairingDialogs` already
/// uses for the invite / done dialogs — a dialog offered once per chat-open, wired alongside it in
/// `ChatController`. The take-over itself reuses the exact confirmation (`SecutgRepairHereConfirm`) the chat
/// menu's existing "Re-pair on this device" entry already shows (PLAN.md 3.7 rule 9) — it already names the
/// three consequences 3.25.6 rule 2 asks for — and adds the one thing that entry does not have: an in-place
/// "sending…" state around the P1 send (PLAN.md 3.25.6 rule 3).
public enum SecutgHandoffDialogs {
    /// "Got it" writes a local-only marker (UserDefaults; never synced, never sent — PLAN.md 3.25.6 rule 3's
    /// "知道了 只写本地标记") keyed to *this exact handoff* (chat + the device that now holds it), so the notice
    /// does not nag again for the same handoff but reappears if the pairing later moves to yet another device.
    private static func ackKey(context: AccountContext, peerId: PeerId, ownDeviceId: String) -> String {
        return "secutg.handoff.ack.\(context.account.peerId.toInt64()).\(peerId.toInt64()).\(ownDeviceId)"
    }

    /// Called once when a chat opens, alongside `SecutgPairingDialogs.observe`. Shows nothing unless this
    /// device currently sits out of the chat's pairing and this exact handoff has not already been acknowledged.
    public static func presentIfNeeded(context: AccountContext, peerId: PeerId, controller: ViewController) {
        guard peerId.namespace == Namespaces.Peer.CloudUser, let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let status = runtime.status(chatPeerId: peerId)
        guard status.pairingState == "other_device", let ownDeviceId = status.ownDeviceId else { return }
        SecutgChatMenu.syncLanguage(context: context)
        let key = ackKey(context: context, peerId: peerId, ownDeviceId: ownDeviceId)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let alert = UIAlertController(
            title: "Si4Gram", // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
            message: SecutgL10n.string("SecutgHandoffNotice", ["device": runtime.deviceDisplayText(ownDeviceId)]),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgHandoffRepairButton"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            presentTakeoverConfirm(context: context, peerId: peerId, controller: controller)
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgHandoffAck"), style: .cancel, handler: { _ in
            UserDefaults.standard.set(true, forKey: key)
        }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    /// PLAN.md 3.25.6 rule 2: the same "在本机接管" confirmation the chat menu's `repairHere` entry shows
    /// (PLAN.md 3.7 rule 9) — `SecutgRepairHereConfirm` already spells out the three consequences.
    public static func presentTakeoverConfirm(context: AccountContext, peerId: PeerId, controller: ViewController) {
        guard SecutgHookRegistry.shared.runtime(for: context.account.peerId) != nil else { return }
        let confirm = UIAlertController(title: SecutgL10n.string("SecutgMenuRepairHere"), message: SecutgL10n.string("SecutgRepairHereConfirm"), preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRepairHere"), style: .destructive, handler: { [weak controller] _ in
            guard let controller else { return }
            performTakeover(context: context, peerId: peerId, controller: controller)
        }))
        confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(confirm, over: controller)
    }

    /// PLAN.md 3.25.6 rule 3: a local-only, in-place progress state — not a new chat-history line — while the
    /// new P1 is sent, in place of the chat menu's `repairHere` entry, which sends instantly with no feedback.
    /// `startPairing` itself is synchronous local key work; the only failure it can actually report here is a
    /// local one (no identity yet). Once the P1 is handed to Postbox, this client's own send / retry pipeline
    /// owns delivery, exactly as it already does for every other pairing message this codebase sends — there is
    /// no separate network-failure signal available to surface, so "failed" here means this local step failed.
    ///
    /// This is the one caller that has shown the user what a takeover costs, so it is the one that states
    /// `confirmedTakeover`. PLAN.md 3.25.6 rule 7's refusal lands here too, and is treated like a failure rather
    /// than a success: the waiting state goes away and the button comes back, so the same tap can be repeated
    /// once the window has run out.
    private static func performTakeover(context: AccountContext, peerId: PeerId, controller: ViewController) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let progress = UIAlertController(title: SecutgL10n.string("SecutgMenuRepairHere"), message: SecutgL10n.string("SecutgRepairHereInProgress"), preferredStyle: .alert)
        SecutgChatMenu.presentSystem(progress, over: controller)
        do {
            switch try runtime.startPairing(chatPeerId: peerId, confirmedTakeover: true) {
            case let .started(p1, _, _):
                SecutgChatMenu.sendText(context: context, peerId: peerId, text: p1)
                progress.dismiss(animated: true)
            case let .tooSoon(seconds):
                failTakeover(context: context, peerId: peerId, controller: controller, progress: progress,
                             message: SecutgL10n.string("SecutgRepairHereTooSoon", ["seconds": "\(seconds)"]))
            case .needsTakeover:
                // Unreachable: this call states the confirmation was shown, and that is the only thing the
                // runtime answers `needsTakeover` about. Kept on the failure path, with the confirmation's own
                // wording, rather than passed over in silence — a future change that makes it reachable should
                // show the user something instead of turning this into a button that does nothing.
                failTakeover(context: context, peerId: peerId, controller: controller, progress: progress,
                             message: SecutgL10n.string("SecutgRepairHereConfirm"))
            }
        } catch {
            failTakeover(context: context, peerId: peerId, controller: controller, progress: progress,
                         message: SecutgL10n.string("SecutgPairFailed", ["error": "\(error)"]))
        }
    }

    /// Rule 3's "failure to send must be retryable, not a silent stall": the in-place waiting state is dropped
    /// and the 〔在本机接管〕 button comes back, so the same tap can be repeated.
    private static func failTakeover(context: AccountContext, peerId: PeerId, controller: ViewController,
                                     progress: UIAlertController, message: String) {
        progress.dismiss(animated: true) { [weak controller] in
            guard let controller else { return }
            let retry = UIAlertController(title: SecutgL10n.string("SecutgMenuRepairHere"), message: message, preferredStyle: .alert)
            retry.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRepairHere"), style: .default, handler: { [weak controller] _ in
                guard let controller else { return }
                performTakeover(context: context, peerId: peerId, controller: controller)
            }))
            retry.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
            SecutgChatMenu.presentSystem(retry, over: controller)
        }
    }
}
