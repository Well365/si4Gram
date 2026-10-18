import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import LocalizedPeerData
import SecutgCore

/// One chat this keyring holds a key for. `hasKey` rather than "encryption is on" on purpose: a chat whose
/// switch is off still has a key, and that key is exactly what the user came here to find (and to back up).
/// Not `private`: the main settings page also reads `secutgKeyedChats` to show the row's own count subtitle
/// (PLAN.md 3.52 row 12, `SecutgSettingsChatsCount`).
struct SecutgKeyedChat: Equatable {
    let peer: EnginePeer
    let memberCount: Int
    let isEncrypted: Bool
    /// SECUTG-HOOK (fix B1): true for a G2 auto-mode group (PLAN.md 3.35) — its key travels the chat
    /// in the clear, so its row must not share `isEncrypted`'s icon even though the switch is on.
    let isObfuscatedGroup: Bool
}

/// PLAN.md 3.29.1 rule 4 ⑤. The keyring answers this directly, so the list is the keyring's real contents —
/// not whatever the chat list happens to show. `keyedChatPeerIds()` hands back dictionary order, which would
/// let rows swap places on every redraw, so it is sorted before it reaches the list.
func secutgKeyedChats(context: AccountContext) -> Signal<[SecutgKeyedChat], NoError> {
    guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else {
        return .single([])
    }
    let peerIds = runtime.keyedChatPeerIds()
    guard !peerIds.isEmpty else {
        return .single([])
    }
    return context.engine.data.get(EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)))
    |> map { peers -> [SecutgKeyedChat] in
        var result: [SecutgKeyedChat] = []
        for peerId in peerIds {
            guard let peer = peers[peerId] ?? nil else { continue }
            let status = runtime.status(chatPeerId: peerId)
            // SECUTG-HOOK (fix B1): same "!isPrivateChat && keyMode == .auto" test as
            // `SecutgFloatingButton.refresh()` — kept in exact sync with it rather than reusing
            // `status.encryptionEnabled`, which is true for a G2 group too (PLAN.md 3.35: the switch
            // is on, it just does not protect against Telegram itself).
            let isObfuscatedGroup = !status.isPrivateChat && status.keyMode == .auto
            result.append(SecutgKeyedChat(peer: peer, memberCount: status.memberCount, isEncrypted: status.encryptionEnabled, isObfuscatedGroup: isObfuscatedGroup))
        }
        return result.sorted(by: { lhs, rhs in
            let l = lhs.peer.compactDisplayTitle
            let r = rhs.peer.compactDisplayTitle
            if l != r { return l.localizedCaseInsensitiveCompare(r) == .orderedAscending }
            return lhs.peer.id < rhs.peer.id
        })
    }
}

/// SECUTG (PLAN.md 3.52 row 12): the 已加密的聊天 sub-page — the same per-chat rows the main settings page used
/// to carry directly (same icon, same description, same tap action), just reached through a disclosure row now,
/// plus the empty-state line the main page never needed because it simply hid the whole group.
private final class SecutgSettingsChatsArguments {
    let openChat: (EnginePeer) -> Void
    init(openChat: @escaping (EnginePeer) -> Void) {
        self.openChat = openChat
    }
}

private enum SecutgSettingsChatsEntry: ItemListNodeEntry {
    case empty(String)
    case chat(Int32, EnginePeer, String, Bool, Bool)

    var section: ItemListSectionId { return 0 }

    var stableId: Int32 {
        switch self {
        case .empty: return 0
        case let .chat(index, _, _, _, _): return 1 + index
        }
    }

    static func <(lhs: SecutgSettingsChatsEntry, rhs: SecutgSettingsChatsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SecutgSettingsChatsArguments
        switch self {
        case let .empty(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .chat(_, peer, label, isEncrypted, isObfuscatedGroup):
            // SECUTG-HOOK (fix B1, carried over unchanged from the old main-page rows): checked before
            // `isEncrypted` — a G2 auto-mode group never reads as "encrypted" even though its switch is on.
            let icon: UIImage?
            if isObfuscatedGroup {
                icon = PresentationResourcesSettings.secutgChatObfuscated
            } else {
                icon = isEncrypted ? PresentationResourcesSettings.secutgChatEncrypted : PresentationResourcesSettings.secutgChatIdle
            }
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder), label: label, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.openChat(peer)
            })
        }
    }
}

public enum SecutgSettingsChatsUI {
    public static func controller(context: AccountContext) -> ViewController {
        SecutgChatMenu.syncLanguage(context: context)

        var controllerRef: (() -> ViewController?)?
        let keyedChats = secutgKeyedChats(context: context)
        let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, keyedChats)
        |> map { presentationData, keyedChats -> (ItemListControllerState, (ItemListNodeState, Any)) in
            SecutgChatMenu.syncLanguage(context: context)
            let arguments = SecutgSettingsChatsArguments(openChat: { peer in
                guard let navigationController = controllerRef?()?.navigationController as? NavigationController else { return }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
            })
            var entries: [SecutgSettingsChatsEntry] = []
            if keyedChats.isEmpty {
                entries.append(.empty(SecutgL10n.string("SecutgSettingsChatsEmpty")))
            } else {
                for (index, chat) in keyedChats.enumerated() {
                    entries.append(.chat(Int32(index), chat.peer, SecutgL10n.string("SecutgSettingsChatDesc", ["count": "\(chat.memberCount)"]), chat.isEncrypted, chat.isObfuscatedGroup))
                }
            }
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(SecutgL10n.string("SecutgSettingsChats")),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
            let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
            return (controllerState, (listState, arguments))
        }
        let controller = ItemListController(context: context, state: signal)
        controllerRef = { [weak controller] in controller }
        return controller
    }
}
