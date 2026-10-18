import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import AccountContext
import SecutgCore
import SecutgRelay

/// SECUTG-HOOK (PLAN.md 3.48) hook ① — compose-time relay routing decisions, and the actual intercept the send
/// chokepoint (`ChatControllerNode.sendCurrentMessage`) runs before its own unmodified body. Everything here is
/// guarded to fall through to ordinary sending on any error or unmet precondition (PLAN.md 3.48.0 rules 3/6):
/// a relay-module problem must never drop a message, never block a normal send, and never do any I/O at all
/// when the global switch is off. The actual dialogs (zero-relay prompt, upload-failure prompt, the image
/// picker) live in `SecutgRelayMenu` (in `SecutgRelay`, which this component already depends on one-way) so
/// this compose path, `SecutgRelayChatController`'s manual rows, and the send-button long-press fallback all
/// show the exact same three dialogs rather than three near-identical copies of them.
public enum SecutgRelayComposeHost {
    /// PLAN.md 3.48.0 rule 3's cheapest possible check — read directly by the send-button long-press hook
    /// (`ChatControllerLoadDisplayNode.swift`) so that hook costs nothing beyond one property read when the
    /// feature is off.
    public static func isGloballyEnabled() -> Bool {
        return SecutgRelayRuntime.shared.appState.current.settings.enabled
    }

    /// Whether the compose tag (PLAN.md 3.48.4) belongs above the composer right now. Zero I/O: reads the
    /// global switch (a cheap property), the one-shot overrides, and `RelayPolicy.shouldAutoRelay` against the
    /// text currently in the box.
    public static func isDue(context: AccountContext, peerId: PeerId, currentText: String) -> Bool {
        guard isGloballyEnabled() else { return false }
        switch SecutgRelayComposeState.peek(peerId: peerId) {
        case .skipNext: return false
        case .forceNext: return true
        case nil: break
        }
        guard !currentText.isEmpty else { return false }
        let appConfig = SecutgRelayRuntime.shared.appState.current
        let accountState = SecutgRelayRuntime.shared.accountState(context: context)
        let chatPolicy = accountState.chatPolicy(chatId: SecutgRelayRuntime.chatKey(peerId))
        guard RelayPolicy.isEnabled(global: appConfig.settings, chat: chatPolicy) else { return false }
        return RelayPolicy.shouldAutoRelay(trigger: appConfig.settings.trigger, textLength: currentText.count, isImage: false)
    }

    /// Short human policy label for the compose tag — "读 1 次 · 1 天" — built the same way
    /// `SecutgRelayChatController` already labels a keep policy, so the two never drift apart.
    public static func policyLabel(context: AccountContext, peerId: PeerId) -> String {
        let appConfig = SecutgRelayRuntime.shared.appState.current
        let accountState = SecutgRelayRuntime.shared.accountState(context: context)
        let chatPolicy = accountState.chatPolicy(chatId: SecutgRelayRuntime.chatKey(peerId))
        let policy = RelayPolicy.effectiveKeepPolicy(global: appConfig.settings, chat: chatPolicy)
        let reads = policy.maxReads == 0
            ? SecutgL10n.string("SecutgRelayReadsUnlimited")
            : SecutgL10n.string("SecutgRelayReadsN", ["count": "\(policy.maxReads)"])
        return "\(reads) · \(ttlLabel(policy.ttlSeconds))"
    }

    private static func ttlLabel(_ seconds: Int) -> String {
        switch seconds {
        case 3600: return SecutgL10n.string("SecutgRelayTtl1h")
        case 86_400: return SecutgL10n.string("SecutgRelayTtl1d")
        case 7 * 86_400: return SecutgL10n.string("SecutgRelayTtl7d")
        case 30 * 86_400: return SecutgL10n.string("SecutgRelayTtl30d")
        default: return SecutgL10n.string("SecutgRelayTtl1d")
        }
    }

    /// The send-button long-press fallback (PLAN.md 3.48.4 "长按发送 →〔通过中转发送…〕"; see this file's own
    /// notes on why this could not be added as a real entry inside `ChatSendMessageActionSheetController`
    /// without a disproportionate diff to an unrelated, complex module — the same escape hatch PLAN.md's prompt
    /// explicitly allows). Interposes only when the global switch is on; tapping "取消" always falls through to
    /// the pre-existing sheet unchanged, so nothing about the original long-press menu is lost — only one extra
    /// tap is added, and only while the feature is enabled.
    public static func presentSendViaRelayChoice(context: AccountContext, peerId: PeerId, over controller: ViewController, onContinue: @escaping () -> Void) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelaySendVia"), style: .default, handler: { _ in
            SecutgRelayComposeState.setForceNext(peerId: peerId)
        }))
        // PLAN.md 3.48.4's image entry reuses the same string (no dedicated "通过中转发送图片" key exists) —
        // distinguished the same way `SecutgRelayChatController.swift`'s own two rows already are.
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelaySendVia") + " (" + SecutgL10n.string("SecutgRelayCardImage", ["size": ""]) + ")", style: .default, handler: { _ in
            SecutgRelayMenu.presentSendImageViaRelay(context: context, peerId: peerId, controller: controller)
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel, handler: { _ in
            onContinue()
        }))
        SecutgRelayPresentation.presentModal(sheet, { [weak controller] in controller?.view.window?.rootViewController ?? controller })
    }

    // MARK: - The actual send-chokepoint intercept (PLAN.md 3.48.0 hook ①, "auto-relay" / "manual force")

    /// An intercepted text send in progress: call `run` exactly once. `nil` from `interceptSend` means "do
    /// nothing, let the chokepoint's own unmodified body run" — the normal case whenever the switch is off, no
    /// override is set, and the text does not meet the auto-relay threshold.
    public final class Intercepted {
        private let context: AccountContext
        private let peerId: PeerId
        private let text: String
        private let controller: () -> ViewController?

        fileprivate init(context: AccountContext, peerId: PeerId, text: String, controller: @escaping () -> ViewController?) {
            self.context = context
            self.peerId = peerId
            self.text = text
            self.controller = controller
        }

        /// `onDirectSend` must send `text` through the chokepoint's ordinary, unmodified path (the caller
        /// re-invokes itself with a bypass flag). `onSent` is called once the `L1:` reference has already been
        /// uploaded AND enqueued (via `SecutgRelaySendFlow.sendText`, the exact function
        /// `SecutgRelayChatController`'s own manual row uses) — the caller only needs to clear its own compose
        /// box at that point, nothing else.
        public func run(onDirectSend: @escaping () -> Void, onSent: @escaping () -> Void) {
            attemptUpload(onDirectSend: onDirectSend, onSent: onSent)
        }

        private func attemptUpload(onDirectSend: @escaping () -> Void, onSent: @escaping () -> Void) {
            guard let controller = controller() else { return }
            let appConfig = SecutgRelayRuntime.shared.appState.current
            guard let relay = appConfig.defaultRelay else {
                // PLAN.md 3.48.4 rule 4 / "绝不静默直发": no relay configured, so this does not send anything at
                // all — not even directly — until the user explicitly chooses to.
                SecutgRelayMenu.presentNoRelayPrompt(context: context, controller: controller)
                return
            }
            let accountState = SecutgRelayRuntime.shared.accountState(context: context)
            let chatPolicy = accountState.chatPolicy(chatId: SecutgRelayRuntime.chatKey(peerId))
            let keepPolicy = RelayPolicy.effectiveKeepPolicy(global: appConfig.settings, chat: chatPolicy)
            SecutgRelaySendFlow.sendText(context: context, peerId: peerId, text: text, relay: relay, keepPolicy: keepPolicy, encrypt: appConfig.settings.encryptContent, completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    onSent()
                case .failure:
                    guard let controller = self.controller() else { return }
                    SecutgRelayMenu.presentUploadFailedPrompt(controller: controller, onRetry: {
                        self.attemptUpload(onDirectSend: onDirectSend, onSent: onSent)
                    }, onSendDirect: {
                        onDirectSend()
                    })
                }
            })
        }
    }

    /// Called once, at the very top of the send chokepoint, before anything else in its body. `controller` lets
    /// this stay inside `SecutgChatMenu` without the chokepoint handing over any of its own internals beyond
    /// "where do I put a view controller" — the same shape `SecutgKeyRequiredPanelNode` already uses for its
    /// own `controller: () -> ViewController?`.
    public static func interceptSend(context: AccountContext, peerId: PeerId, text: String, controller: @escaping () -> ViewController?) -> Intercepted? {
        guard isGloballyEnabled() else { return nil }
        let override = SecutgRelayComposeState.consume(peerId: peerId)
        if case .skipNext = override { return nil }
        let forced: Bool
        if case .forceNext = override { forced = true } else { forced = false }
        guard !text.isEmpty else { return nil }
        if !forced {
            let appConfig = SecutgRelayRuntime.shared.appState.current
            let accountState = SecutgRelayRuntime.shared.accountState(context: context)
            let chatPolicy = accountState.chatPolicy(chatId: SecutgRelayRuntime.chatKey(peerId))
            guard RelayPolicy.isEnabled(global: appConfig.settings, chat: chatPolicy) else { return nil }
            guard RelayPolicy.shouldAutoRelay(trigger: appConfig.settings.trigger, textLength: text.count, isImage: false) else { return nil }
        }
        return Intercepted(context: context, peerId: peerId, text: text, controller: controller)
    }
}
