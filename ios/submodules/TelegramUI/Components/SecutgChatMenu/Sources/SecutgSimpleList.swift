import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

/// SECUTG: a small row vocabulary for the PLAN.md 3.40 / 3.46 pages (API credentials gate and settings, security
/// check-up), rendered with the same `ItemListController` items as every other settings screen. A page is a list
/// of sections of plain rows; taps and edits come back by row id, so the entries stay `Equatable` and the page's
/// state lives in one place (the caller's signal).
public enum SecutgListRow: Equatable {
    case header(String)
    case text(String)
    case action(id: String, title: String, kind: ItemListActionKind)
    case disclosure(id: String, title: String, label: String)
    case input(id: String, title: String, text: String, placeholder: String, isNumber: Bool)
    /// PLAN.md 3.52: an on/off row with the usual per-state subtitle (e.g. "SecutgWipeConfirmToggleOn/Off");
    /// pass "" when a sub-page's toggle needs none.
    case toggle(id: String, title: String, text: String, value: Bool)
    /// A disclosure row with no chevron, for a row whose tap copies something to the pasteboard instead of
    /// pushing anything — PLAN.md 3.52's copyable commands and device code rows. The caller's `tapped(id)`
    /// already knows what to copy, so no value travels through the row itself.
    case copyable(id: String, title: String, label: String)
}

public struct SecutgListSection: Equatable {
    public let rows: [SecutgListRow]

    public init(_ rows: [SecutgListRow]) {
        self.rows = rows
    }
}

final class SecutgListArguments {
    let tapped: (String) -> Void
    let edited: (String, String) -> Void
    let toggled: (String, Bool) -> Void

    init(tapped: @escaping (String) -> Void, edited: @escaping (String, String) -> Void, toggled: @escaping (String, Bool) -> Void) {
        self.tapped = tapped
        self.edited = edited
        self.toggled = toggled
    }
}

struct SecutgListEntry: ItemListNodeEntry {
    let sectionIndex: Int32
    let index: Int32
    let row: SecutgListRow

    var section: ItemListSectionId { return sectionIndex }
    var stableId: Int32 { return sectionIndex * 10000 + index }

    static func < (lhs: SecutgListEntry, rhs: SecutgListEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SecutgListArguments
        switch row {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, multiline: true, sectionId: section)
        case let .text(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .action(id, title, kind):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: kind, alignment: .natural, sectionId: section, style: .blocks, action: {
                arguments.tapped(id)
            })
        case let .disclosure(id, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, labelStyle: .multilineDetailText, sectionId: section, style: .blocks, action: {
                arguments.tapped(id)
            })
        case let .input(id, title, text, placeholder, isNumber):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: title, textColor: presentationData.theme.list.itemPrimaryTextColor), text: text, placeholder: placeholder, type: isNumber ? .number : .regular(capitalization: false, autocorrection: false), spacing: 12.0, sectionId: section, textUpdated: { value in
                arguments.edited(id, value)
            }, action: {})
        case let .toggle(id, title, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text.isEmpty ? nil : text, value: value, sectionId: section, style: .blocks, updated: { value in
                arguments.toggled(id, value)
            })
        case let .copyable(id, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, labelStyle: .multilineDetailText, sectionId: section, style: .blocks, disclosureStyle: .none, action: {
                arguments.tapped(id)
            })
        }
    }
}

/// An `ItemListController` over `content`; the title and the sections are re-read on every emission.
func secutgListController(presentationData: PresentationData, updatedPresentationData: Signal<PresentationData, NoError>,
                          content: Signal<(title: String, sections: [SecutgListSection]), NoError>,
                          tapped: @escaping (String) -> Void, edited: @escaping (String, String) -> Void = { _, _ in },
                          toggled: @escaping (String, Bool) -> Void = { _, _ in },
                          hasBackButton: Bool = true) -> ItemListController {
    let arguments = SecutgListArguments(tapped: tapped, edited: edited, toggled: toggled)
    let signal = combineLatest(queue: .mainQueue(), updatedPresentationData, content)
    |> map { presentationData, content -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(content.title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: hasBackButton ? ItemListBackButton(title: presentationData.strings.Common_Back) : nil)
        var entries: [SecutgListEntry] = []
        for (sectionIndex, section) in content.sections.enumerated() {
            for (index, row) in section.rows.enumerated() {
                entries.append(SecutgListEntry(sectionIndex: Int32(sectionIndex), index: Int32(index), row: row))
            }
        }
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(presentationData: ItemListPresentationData(presentationData),
                              updatedPresentationData: updatedPresentationData |> map { ItemListPresentationData($0) },
                              state: signal, tabBarItem: nil)
}
