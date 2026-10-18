import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// The three places `SecutgChatMenu` (and the chat's own context menu) reach into this component:
/// PLAN.md 3.48.0 hook ③ (settings row push), hook ④ (chat lock-menu row push), hook ⑥ (own-message context
/// menu). `SecutgChatMenu` depends on `SecutgRelay`; `SecutgRelay` never depends back on it (see
/// `SecutgRelayPresentation`'s note) — this file is the whole of that one-directional surface.
public enum SecutgRelayMenu {
    public static func pushSettingsController(context: AccountContext, controller: ViewController) {
        controller.push(SecutgRelaySettingsController.controller(context: context))
    }

    public static func pushChatController(context: AccountContext, peerId: PeerId, controller: ViewController) {
        controller.push(SecutgRelayChatController.controller(context: context, peerId: peerId))
    }

    public struct ContextAction {
        public let title: String
        public let destructive: Bool
        public let perform: () -> Void
    }

    /// PLAN.md 3.48.0 hook ⑥: 〔查看状态〕/〔撤回中转内容〕 on this account's own already-sent relay messages.
    /// Empty for anything else — an incoming relay message, an ordinary message, or one this device did not
    /// send through a relay (its sent-item record lives on the sending device only).
    public static func contextActions(context: AccountContext, message: Message, controller: ViewController) -> [ContextAction] {
        guard SecutgRelayCard.isOwnRelayMessage(context: context, message: message),
              let sentItem = SecutgRelayCard.sentItem(context: context, message: message) else {
            return []
        }
        var actions: [ContextAction] = []
        actions.append(ContextAction(title: SecutgL10n.string("SecutgRelayStatus"), destructive: false, perform: {
            showStatus(sentItem: sentItem, controller: controller)
        }))
        if !sentItem.revoked, let token = sentItem.deleteToken {
            actions.append(ContextAction(title: SecutgL10n.string("SecutgRelayRevoke"), destructive: true, perform: {
                confirmRevoke(context: context, sentItem: sentItem, deleteToken: token, controller: controller)
            }))
        }
        return actions
    }

    private static func present(_ alert: UIAlertController, controller: ViewController) {
        SecutgRelayPresentation.presentModal(alert, { controller.view.window?.rootViewController ?? controller })
    }

    // MARK: - Shared dialogs (PLAN.md 3.48.4), reused by SecutgRelayChatController and by SecutgChatMenu's
    // compose-time hooks (SecutgRelayComposeHost) so the three send-through-relay entry points (the per-chat
    // screen, the compose tag / auto-relay, and the send-button long-press fallback) never drift into three
    // slightly different dialogs.

    /// The zero-relay prompt, actionable (`SecutgRelayAdd` navigates to the add-relay flow) rather than the
    /// single-OK "needs a token" alert this used to be. PLAN.md 3.48.4 rule 4 / "绝不静默直发": this never sends
    /// anything, direct or otherwise — the two buttons are "go configure one" and "never mind".
    public static func presentNoRelayPrompt(context: AccountContext, controller: ViewController) {
        let alert = UIAlertController(title: nil, message: SecutgL10n.string("SecutgRelayNeedsToken"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayAdd"), style: .default, handler: { _ in
            controller.push(SecutgRelaySettingsController.controller(context: context))
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
        present(alert, controller: controller)
    }

    /// The upload-failure dialog. `onSendDirect` is nil wherever "send the original content directly" is not a
    /// safe reuse of existing code (e.g. the already-picked-image path, which would otherwise have to re-enter
    /// the ordinary media/attachment pipeline from outside it) — in that case this degrades to retry/cancel only,
    /// which is still a strict improvement over the single-OK alert it replaces.
    public static func presentUploadFailedPrompt(controller: ViewController, onRetry: @escaping () -> Void, onSendDirect: (() -> Void)?) {
        let alert = UIAlertController(title: nil, message: SecutgL10n.string("SecutgRelayUploadFailed", ["reason": "network"]), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayRetry"), style: .default, handler: { _ in onRetry() }))
        if let onSendDirect {
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelaySendDirect"), style: .default, handler: { _ in onSendDirect() }))
        }
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
        present(alert, controller: controller)
    }

    /// PLAN.md 3.48.4's image entry for the send-button long-press fallback (see `SecutgChatMenu`'s own notes on
    /// why this is not a real attachment-menu row in this pass). Reuses `SecutgRelayChatController`'s own
    /// image-picking and upload code verbatim rather than reimplementing it here.
    public static func presentSendImageViaRelay(context: AccountContext, peerId: PeerId, controller: ViewController) {
        guard let relay = SecutgRelayRuntime.shared.appState.current.defaultRelay else {
            presentNoRelayPrompt(context: context, controller: controller)
            return
        }
        let picker = SecutgRelayImagePicker(onPicked: { data, mime in
            uploadImageViaRelay(context: context, peerId: peerId, relay: relay, imageData: data, mime: mime, controller: controller)
        })
        SecutgRelayPresentation.presentModal(picker.makePickerController(), { controller.view.window?.rootViewController ?? controller })
    }

    private static func uploadImageViaRelay(context: AccountContext, peerId: PeerId, relay: RelayEndpoint, imageData: Data, mime: String, controller: ViewController) {
        let appConfig = SecutgRelayRuntime.shared.appState.current
        let accountState = SecutgRelayRuntime.shared.accountState(context: context)
        let chatPolicy = accountState.chatPolicy(chatId: SecutgRelayRuntime.chatKey(peerId))
        let keepPolicy = RelayPolicy.effectiveKeepPolicy(global: appConfig.settings, chat: chatPolicy)
        SecutgRelaySendFlow.sendImage(context: context, peerId: peerId, imageData: imageData, mime: mime, relay: relay, keepPolicy: keepPolicy, encrypt: appConfig.settings.encryptContent, stripExif: appConfig.settings.stripExif, completion: { result in
            if case .failure = result {
                // No "send directly" here (PLAN.md 3.48 rule 5): that would mean re-entering the ordinary
                // media/attachment pipeline from outside it, which this pass deliberately does not do.
                presentUploadFailedPrompt(controller: controller, onRetry: {
                    uploadImageViaRelay(context: context, peerId: peerId, relay: relay, imageData: imageData, mime: mime, controller: controller)
                }, onSendDirect: nil)
            }
        })
    }

    private static func showStatus(sentItem: RelaySentItem, controller: ViewController) {
        SecutgRelayRuntime.shared.client.meta(baseURL: sentItem.relayURL, id: sentItem.id) { result in
            DispatchQueue.main.async {
                let message: String
                switch result {
                case .success(let meta):
                    let reads = meta.readsLeft.map { "\($0)" } ?? SecutgL10n.string("SecutgRelayReadsUnlimited")
                    message = SecutgL10n.string("SecutgRelayStatusLine", ["reads": reads, "time": "\(meta.expiresAt)"])
                case .failure:
                    message = SecutgL10n.string("SecutgRelayStatusGone")
                }
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default))
                present(alert, controller: controller)
            }
        }
    }

    private static func confirmRevoke(context: AccountContext, sentItem: RelaySentItem, deleteToken: String, controller: ViewController) {
        let confirm = UIAlertController(title: nil, message: SecutgL10n.string("SecutgRelayRevokeConfirm"), preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayRevoke"), style: .destructive, handler: { _ in
            let accountState = SecutgRelayRuntime.shared.accountState(context: context)
            accountState.markRevoked(id: sentItem.id)
            SecutgRelayRuntime.shared.client.delete(baseURL: sentItem.relayURL, id: sentItem.id, deleteToken: deleteToken) { result in
                if case .failure = result {
                    accountState.markRevoked(id: sentItem.id, pendingRetry: true)
                }
            }
        }))
        confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
        present(confirm, controller: controller)
    }
}
