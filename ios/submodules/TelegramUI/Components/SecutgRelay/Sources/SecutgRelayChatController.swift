import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import SecutgCore

/// PLAN.md 3.48.4 「每个聊天（锁菜单 → 中转）」: follow-global / always-on / always-off, this chat's own keep
/// policy, and the two send-through-relay entries (PLAN.md 3.48.0 hook ① "send entry", implemented here as an
/// equivalent screen entry rather than inside the compose bar itself — see the component's own notes).
private final class SecutgRelayChatArguments {
    let pickMode: () -> Void
    let pickPolicy: () -> Void
    let pickRelay: () -> Void
    let sendText: () -> Void
    let sendImage: () -> Void
    init(pickMode: @escaping () -> Void, pickPolicy: @escaping () -> Void, pickRelay: @escaping () -> Void, sendText: @escaping () -> Void, sendImage: @escaping () -> Void) {
        self.pickMode = pickMode
        self.pickPolicy = pickPolicy
        self.pickRelay = pickRelay
        self.sendText = sendText
        self.sendImage = sendImage
    }
}

private enum SecutgRelayChatEntry: ItemListNodeEntry {
    case mode(String)
    case policy(String)
    // SECUTG-HOOK (PLAN.md 3.48.4 gap d): "本聊天使用的中转" — between the mode and keep-policy rows.
    case relay(String)
    case sendText(String)
    case sendImage(String)

    var section: ItemListSectionId { return 0 }

    var stableId: Int32 {
        switch self {
        case .mode: return 0
        case .relay: return 1
        case .policy: return 2
        case .sendText: return 3
        case .sendImage: return 4
        }
    }

    static func ==(lhs: SecutgRelayChatEntry, rhs: SecutgRelayChatEntry) -> Bool {
        return lhs.stableId == rhs.stableId && String(describing: lhs) == String(describing: rhs)
    }

    static func <(lhs: SecutgRelayChatEntry, rhs: SecutgRelayChatEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SecutgRelayChatArguments
        switch self {
        case let .mode(label):
            return ItemListDisclosureItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayChatTitle"), label: label, sectionId: self.section, style: .blocks, action: arguments.pickMode)
        case let .policy(label):
            return ItemListDisclosureItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayChatPolicy"), label: label, sectionId: self.section, style: .blocks, action: arguments.pickPolicy)
        case let .relay(label):
            return ItemListDisclosureItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayChatRelay"), label: label, sectionId: self.section, style: .blocks, action: arguments.pickRelay)
        case let .sendText(title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: arguments.sendText)
        case let .sendImage(title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: arguments.sendImage)
        }
    }
}

public enum SecutgRelayChatController {
    public static func controller(context: AccountContext, peerId: PeerId) -> ViewController {
        let accountState = SecutgRelayRuntime.shared.accountState(context: context)
        let chatKey = SecutgRelayRuntime.chatKey(peerId)
        let statePromise = Promise<RelayChatPolicy>()
        func reload() { statePromise.set(.single(accountState.chatPolicy(chatId: chatKey))) }
        reload()

        var getControllerImpl: (() -> ViewController?)?

        func modeLabel(_ mode: RelayChatMode) -> String {
            switch mode {
            case .followGlobal: return SecutgL10n.string("SecutgRelayChatFollow")
            case .alwaysOn: return SecutgL10n.string("SecutgRelayChatAlways")
            case .alwaysOff: return SecutgL10n.string("SecutgRelayChatNever")
            }
        }
        func policyLabel(_ policy: RelayKeepPolicy?) -> String {
            guard let policy else { return SecutgL10n.string("SecutgRelayDefault") }
            let reads = policy.maxReads == 0 ? SecutgL10n.string("SecutgRelayReadsUnlimited") : SecutgL10n.string("SecutgRelayReadsN", ["count": "\(policy.maxReads)"])
            return "\(reads) · \(ttlLabelForChat(policy.ttlSeconds))"
        }
        // SECUTG-HOOK (PLAN.md 3.48.4 gap d): this chat's own relay choice wins when set and still configured;
        // a relay removed after being chosen falls back to the global default rather than crashing or sending
        // nowhere (PLAN.md 3.48.0 rule 6).
        func currentRelay() -> RelayEndpoint? {
            let config = SecutgRelayRuntime.shared.appState.current
            if let relayId = accountState.chatPolicy(chatId: chatKey).relayId, let match = config.relays.first(where: { $0.id == relayId }) {
                return match
            }
            return config.defaultRelay
        }
        func relayLabel(_ policy: RelayChatPolicy) -> String {
            guard let relayId = policy.relayId, let match = SecutgRelayRuntime.shared.appState.current.relays.first(where: { $0.id == relayId }) else {
                return SecutgL10n.string("SecutgRelayDefault")
            }
            return RelayHost.classify(match.urlString)?.host ?? match.urlString
        }
        func effectiveSettings() -> RelaySettings { SecutgRelayRuntime.shared.appState.current.settings }

        func presentAlert(_ alert: UIAlertController) {
            guard let controller = getControllerImpl?() else { return }
            SecutgRelayPresentation.presentModal(alert, { controller.view.window?.rootViewController ?? controller })
        }

        let arguments = SecutgRelayChatArguments(
            pickMode: {
                let sheet = UIAlertController(title: SecutgL10n.string("SecutgRelayChatTitle"), message: nil, preferredStyle: .actionSheet)
                for mode in [RelayChatMode.followGlobal, .alwaysOn, .alwaysOff] {
                    sheet.addAction(UIAlertAction(title: modeLabel(mode), style: .default, handler: { _ in
                        var policy = accountState.chatPolicy(chatId: chatKey)
                        policy.mode = mode
                        accountState.setChatPolicy(chatId: chatKey, policy: policy)
                        reload()
                    }))
                }
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
                presentAlert(sheet)
            },
            pickPolicy: {
                let sheet = UIAlertController(title: SecutgL10n.string("SecutgRelayChatPolicy"), message: nil, preferredStyle: .actionSheet)
                let presets: [RelayKeepPolicy?] = [nil, RelayKeepPolicy(maxReads: 1, ttlSeconds: 86_400), RelayKeepPolicy(maxReads: 3, ttlSeconds: 7 * 86_400), RelayKeepPolicy(maxReads: 0, ttlSeconds: 30 * 86_400)]
                for preset in presets {
                    sheet.addAction(UIAlertAction(title: policyLabel(preset), style: .default, handler: { _ in
                        var policy = accountState.chatPolicy(chatId: chatKey)
                        policy.keepPolicy = preset
                        accountState.setChatPolicy(chatId: chatKey, policy: policy)
                        reload()
                    }))
                }
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
                presentAlert(sheet)
            },
            pickRelay: {
                let sheet = UIAlertController(title: SecutgL10n.string("SecutgRelayChatRelay"), message: nil, preferredStyle: .actionSheet)
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayDefault"), style: .default, handler: { _ in
                    var policy = accountState.chatPolicy(chatId: chatKey)
                    policy.relayId = nil
                    accountState.setChatPolicy(chatId: chatKey, policy: policy)
                    reload()
                }))
                for relay in SecutgRelayRuntime.shared.appState.current.relays {
                    let label = RelayHost.classify(relay.urlString)?.host ?? relay.urlString
                    sheet.addAction(UIAlertAction(title: label, style: .default, handler: { _ in
                        var policy = accountState.chatPolicy(chatId: chatKey)
                        policy.relayId = relay.id
                        accountState.setChatPolicy(chatId: chatKey, policy: policy)
                        reload()
                    }))
                }
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
                presentAlert(sheet)
            },
            sendText: {
                guard let controller = getControllerImpl?() else { return }
                guard let relay = currentRelay() else {
                    SecutgRelayMenu.presentNoRelayPrompt(context: context, controller: controller)
                    return
                }
                let composer = UIAlertController(title: SecutgL10n.string("SecutgRelaySendVia"), message: nil, preferredStyle: .alert)
                composer.addTextField(configurationHandler: { _ in })
                composer.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelaySendVia"), style: .default, handler: { _ in
                    guard let text = composer.textFields?.first?.text, !text.isEmpty else { return }
                    func attempt(_ text: String) {
                        let policy = RelayPolicy.effectiveKeepPolicy(global: effectiveSettings(), chat: accountState.chatPolicy(chatId: chatKey))
                        SecutgRelaySendFlow.sendText(context: context, peerId: peerId, text: text, relay: relay, keepPolicy: policy, encrypt: effectiveSettings().encryptContent, completion: { result in
                            DispatchQueue.main.async {
                                if case .failure = result, let controller = getControllerImpl?() {
                                    SecutgRelayMenu.presentUploadFailedPrompt(controller: controller, onRetry: {
                                        attempt(text)
                                    }, onSendDirect: {
                                        let message = EnqueueMessage.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
                                        let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [message]).startStandalone()
                                    })
                                }
                            }
                        })
                    }
                    attempt(text)
                }))
                composer.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
                presentAlert(composer)
            },
            sendImage: {
                guard let controller = getControllerImpl?() else { return }
                guard let relay = currentRelay() else {
                    SecutgRelayMenu.presentNoRelayPrompt(context: context, controller: controller)
                    return
                }
                let picker = SecutgRelayImagePicker(onPicked: { data, mime in
                    func attempt() {
                        let policy = RelayPolicy.effectiveKeepPolicy(global: effectiveSettings(), chat: accountState.chatPolicy(chatId: chatKey))
                        SecutgRelaySendFlow.sendImage(context: context, peerId: peerId, imageData: data, mime: mime, relay: relay, keepPolicy: policy, encrypt: effectiveSettings().encryptContent, stripExif: effectiveSettings().stripExif, completion: { result in
                            DispatchQueue.main.async {
                                if case .failure = result, let controller = getControllerImpl?() {
                                    // No "send directly" (PLAN.md 3.48 rule 5): that would mean re-entering the
                                    // ordinary media/attachment pipeline from outside it, which this pass
                                    // deliberately does not do — see this file's report notes.
                                    SecutgRelayMenu.presentUploadFailedPrompt(controller: controller, onRetry: {
                                        attempt()
                                    }, onSendDirect: nil)
                                }
                            }
                        })
                    }
                    attempt()
                })
                SecutgRelayPresentation.presentModal(picker.makePickerController(), { controller.view.window?.rootViewController ?? controller })
            }
        )

        let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
        |> map { presentationData, policy -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(SecutgL10n.string("SecutgRelayChatTitle")),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
            let entries: [SecutgRelayChatEntry] = [
                .mode(modeLabel(policy.mode)),
                .relay(relayLabel(policy)),
                .policy(policyLabel(policy.keepPolicy)),
                .sendText(SecutgL10n.string("SecutgRelaySendVia")),
                .sendImage(SecutgL10n.string("SecutgRelaySendVia") + " (" + SecutgL10n.string("SecutgRelayCardImage", ["size": ""]) + ")"),
            ]
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: entries,
                style: .blocks,
                animateChanges: false)
            return (controllerState, (listState, arguments))
        }

        let controller = ItemListController(context: context, state: signal)
        getControllerImpl = { [weak controller] in controller }
        return controller
    }
}

private func ttlLabelForChat(_ seconds: Int) -> String {
    switch seconds {
    case 3600: return SecutgL10n.string("SecutgRelayTtl1h")
    case 86_400: return SecutgL10n.string("SecutgRelayTtl1d")
    case 7 * 86_400: return SecutgL10n.string("SecutgRelayTtl7d")
    case 30 * 86_400: return SecutgL10n.string("SecutgRelayTtl30d")
    default: return SecutgL10n.string("SecutgRelayTtl1d")
    }
}
