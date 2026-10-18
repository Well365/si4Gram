import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import SecutgCore

/// PLAN.md 3.48.4 「我发出的中转内容」: this account's sent items, with 查看状态 (meta) / 撤回 per row, and a
/// retry for a withdraw that failed to reach the relay (PLAN.md 3.48.7 §4).
private final class SecutgRelaySentArguments {
    let openItem: (RelaySentItem) -> Void
    init(openItem: @escaping (RelaySentItem) -> Void) { self.openItem = openItem }
}

private enum SecutgRelaySentEntry: ItemListNodeEntry {
    case empty(String)
    case item(Int32, RelaySentItem)

    var section: ItemListSectionId { return 0 }

    var stableId: Int32 {
        switch self {
        case .empty: return 0
        case let .item(index, _): return index + 1
        }
    }

    static func ==(lhs: SecutgRelaySentEntry, rhs: SecutgRelaySentEntry) -> Bool {
        return lhs.stableId == rhs.stableId && String(describing: lhs) == String(describing: rhs)
    }

    static func <(lhs: SecutgRelaySentEntry, rhs: SecutgRelaySentEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SecutgRelaySentArguments
        switch self {
        case let .empty(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .item(_, sentItem):
            let kind = sentItem.contentType == .text ? "⇄" : "⇄🖼"
            var label = sentItem.revoked ? SecutgL10n.string("SecutgRelayRevoked") : ""
            if sentItem.pendingRevokeRetry { label += " " + SecutgL10n.string("SecutgRelayRetry") }
            return ItemListDisclosureItem(presentationData: presentationData, title: "\(kind) \(sentItem.relayURL)", label: label, sectionId: self.section, style: .blocks, action: { arguments.openItem(sentItem) })
        }
    }
}

public enum SecutgRelaySentItemsController {
    public static func controller(context: AccountContext) -> ViewController {
        let statePromise = Promise<[RelaySentItem]>()
        func reload() {
            statePromise.set(.single(SecutgRelayRuntime.shared.accountState(context: context).current.sentItems.reversed()))
        }
        reload()

        var getControllerImpl: (() -> ViewController?)?
        let arguments = SecutgRelaySentArguments(openItem: { sentItem in
            guard let controller = getControllerImpl?() else { return }
            let sheet = UIAlertController(title: sentItem.relayURL, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayStatus"), style: .default, handler: { _ in
                SecutgRelayRuntime.shared.client.meta(baseURL: sentItem.relayURL, id: sentItem.id) { result in
                    DispatchQueue.main.async {
                        guard let controller = getControllerImpl?() else { return }
                        let message: String
                        switch result {
                        case .success(let meta):
                            let readsText = meta.readsLeft.map { "\($0)" } ?? SecutgL10n.string("SecutgRelayReadsUnlimited")
                            message = SecutgL10n.string("SecutgRelayStatusLine", ["reads": readsText, "time": "\(meta.expiresAt)"])
                        case .failure:
                            message = SecutgL10n.string("SecutgRelayStatusGone")
                        }
                        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default))
                        SecutgRelayPresentation.presentModal(alert, { controller.view.window?.rootViewController ?? controller })
                    }
                }
            }))
            if !sentItem.revoked, let token = sentItem.deleteToken {
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayRevoke"), style: .destructive, handler: { _ in
                    let confirm = UIAlertController(title: nil, message: SecutgL10n.string("SecutgRelayRevokeConfirm"), preferredStyle: .alert)
                    confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayRevoke"), style: .destructive, handler: { _ in
                        let accountState = SecutgRelayRuntime.shared.accountState(context: context)
                        accountState.markRevoked(id: sentItem.id)
                        reload()
                        SecutgRelayRuntime.shared.client.delete(baseURL: sentItem.relayURL, id: sentItem.id, deleteToken: token) { result in
                            if case .failure = result {
                                accountState.markRevoked(id: sentItem.id, pendingRetry: true)
                                DispatchQueue.main.async { reload() }
                            }
                        }
                    }))
                    confirm.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
                    guard let controller = getControllerImpl?() else { return }
                    SecutgRelayPresentation.presentModal(confirm, { controller.view.window?.rootViewController ?? controller })
                }))
            }
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
            SecutgRelayPresentation.presentModal(sheet, { controller.view.window?.rootViewController ?? controller })
        })

        let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
        |> map { presentationData, items -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(SecutgL10n.string("SecutgRelaySent")),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
            let entries: [SecutgRelaySentEntry] = items.isEmpty
                ? [.empty(SecutgL10n.string("SecutgRelaySentEmpty"))]
                : items.enumerated().map { .item(Int32($0.offset), $0.element) }
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
