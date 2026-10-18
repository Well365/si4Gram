import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import ItemListUI
import PresentationDataUtils
import Postbox
import TelegramCore
import SecutgCore

/// SECUTG: PLAN.md 3.49 rule 3 / 6 — the lock menu's "更多…" is a titled, three-section page on iOS now
/// (查看 / 备份 / 危险) instead of a second action sheet, the one client whose primary surface (`UIAlertController`)
/// cannot draw a section header at all. Every row here runs the exact `SecutgChatMenu.Entry` the old sheet did —
/// same id, same handler, same dialogs — this file only lays the same entries out with real headers and red
/// text where `MenuLayout.isDanger` says so.
private enum SecutgMoreEntry: ItemListNodeEntry {
    case header(MenuLayout.MoreSection)
    case row(MenuLayout.MoreSection, Int32, String, String, Bool)

    var section: ItemListSectionId {
        switch self {
        case let .header(section): return Int32(section.rawValue)
        case let .row(section, _, _, _, _): return Int32(section.rawValue)
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(section): return Int32(section.rawValue) * 1000
        case let .row(section, rank, _, _, _): return Int32(section.rawValue) * 1000 + 1 + rank
        }
    }

    static func <(lhs: SecutgMoreEntry, rhs: SecutgMoreEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    private static func title(for section: MenuLayout.MoreSection) -> String {
        switch section {
        case .view: return SecutgL10n.string("SecutgMenuSectionView")
        case .backup: return SecutgL10n.string("SecutgMenuSectionBackup")
        case .danger: return SecutgL10n.string("SecutgMenuSectionDanger")
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let runners = arguments as! [String: () -> Void]
        switch self {
        case let .header(section):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: SecutgMoreEntry.title(for: section), sectionId: self.section)
        case let .row(_, _, id, title, destructive):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: destructive ? .destructive : .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                runners[id]?()
            })
        }
    }
}

/// Builds the page `SecutgChatMenu.presentList(.more, ...)` pushes. `entries` is exactly what
/// `SecutgChatMenu.list(.more, ...)` already decided this chat offers (private or group, admin or not) — this
/// function only groups and runs them; it never decides presence.
func secutgMoreListController(entries: [SecutgChatMenu.Entry], context: AccountContext, peerId: PeerId, hostController: ViewController) -> ViewController {
    var byId: [MenuLayout.Id: SecutgChatMenu.Entry] = [:]
    var ids: [MenuLayout.Id] = []
    for entry in entries {
        // PLAN.md 3.49 / menu-layout-expectations.json: "更多…"'s own `import` entry (a private chat's "导入
        // 对方密钥…") is `importManual` in the shared table, distinct from section ③'s `import`
        // (`MenuLayout.Id.importKey`, a group's own first-key/import cluster) — the two never appear in the same
        // list, since they come from two different functions.
        let canonicalRaw = entry.id == "import" ? "importManual" : entry.id
        guard let id = MenuLayout.Id(rawValue: canonicalRaw) else {
            assertionFailure("secutgMoreListController: \(entry.id) has no MenuLayout.Id — add one before offering it.")
            continue
        }
        ids.append(id)
        byId[id] = entry
    }
    let sections = MenuLayout.moreSections(ids)

    // Every row runs the exact entry it always did: a plain entry fires its handler, a second-level list
    // (`transfer`) pops that list exactly as it did from the old action sheet.
    let runners: [String: () -> Void] = Dictionary(uniqueKeysWithValues: entries.map { entry in
        (entry.id, { [weak hostController] in
            guard let hostController else { return }
            if let kind = entry.list {
                SecutgChatMenu.presentList(kind, context: context, peerId: peerId, controller: hostController, sourceView: nil)
            } else {
                entry.handler()
            }
        })
    })

    var listEntries: [SecutgMoreEntry] = []
    for (section, sectionIds) in sections {
        listEntries.append(.header(section))
        for (rank, id) in sectionIds.enumerated() {
            guard let entry = byId[id] else { continue }
            listEntries.append(.row(section, Int32(rank), entry.id, entry.title, MenuLayout.isDanger(id)))
        }
    }

    let signal: Signal<(ItemListControllerState, (ItemListNodeState, Any)), NoError> = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(SecutgChatMenu.title(of: .more)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: listEntries,
            style: .blocks)
        return (controllerState, (listState, runners as Any))
    }

    return ItemListController(context: context, state: signal)
}
