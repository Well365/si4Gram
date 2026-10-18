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

/// PLAN.md 3.48.4: 设置 → secuTG → 中转. Reached only from `SecutgSettingsController`'s own new row (the "one
/// settings row" hook point, PLAN.md 3.48.0) and from the chat lock-menu row's "中转设置" shortcut — nothing
/// upstream needs to know this screen's internals, which is what keeps this file freely rewritable.
private final class SecutgRelayArguments {
    let setEnabled: (Bool) -> Void
    let setAutoLongText: (Bool) -> Void
    let setAutoImageAlways: (Bool) -> Void
    let pickReads: () -> Void
    let pickTtl: () -> Void
    let setEncrypt: (Bool) -> Void
    let setStripExif: (Bool) -> Void
    let setShowCards: (Bool) -> Void
    let setAskUnknown: (Bool) -> Void
    let setAllowInsecure: (Bool) -> Void
    let addRelay: () -> Void
    let removeRelay: (String) -> Void
    let setDefaultRelay: (String) -> Void
    let testRelay: (RelayEndpoint) -> Void
    let removeTrusted: (String) -> Void
    let openSentItems: () -> Void
    let openGuide: () -> Void
    // SECUTG-HOOK (PLAN.md 3.48.9): 〔如何部署属于自己的信息中转〕.
    let openDeploy: () -> Void

    init(setEnabled: @escaping (Bool) -> Void, setAutoLongText: @escaping (Bool) -> Void, setAutoImageAlways: @escaping (Bool) -> Void, pickReads: @escaping () -> Void, pickTtl: @escaping () -> Void, setEncrypt: @escaping (Bool) -> Void, setStripExif: @escaping (Bool) -> Void, setShowCards: @escaping (Bool) -> Void, setAskUnknown: @escaping (Bool) -> Void, setAllowInsecure: @escaping (Bool) -> Void, addRelay: @escaping () -> Void, removeRelay: @escaping (String) -> Void, setDefaultRelay: @escaping (String) -> Void, testRelay: @escaping (RelayEndpoint) -> Void, removeTrusted: @escaping (String) -> Void, openSentItems: @escaping () -> Void, openGuide: @escaping () -> Void, openDeploy: @escaping () -> Void) {
        self.setEnabled = setEnabled
        self.setAutoLongText = setAutoLongText
        self.setAutoImageAlways = setAutoImageAlways
        self.pickReads = pickReads
        self.pickTtl = pickTtl
        self.setEncrypt = setEncrypt
        self.setStripExif = setStripExif
        self.setShowCards = setShowCards
        self.setAskUnknown = setAskUnknown
        self.setAllowInsecure = setAllowInsecure
        self.addRelay = addRelay
        self.removeRelay = removeRelay
        self.setDefaultRelay = setDefaultRelay
        self.testRelay = testRelay
        self.removeTrusted = removeTrusted
        self.openSentItems = openSentItems
        self.openGuide = openGuide
        self.openDeploy = openDeploy
    }
}

private enum SecutgRelaySection: Int32 {
    case guide
    case main
    case policy
    case privacy
    case receive
    case relays
    case trust
    case sent
}

private let relayStableIdBase: Int32 = 100
private let trustStableIdBase: Int32 = 1000

private enum SecutgRelayEntry: ItemListNodeEntry {
    // PLAN.md 3.48.8: 〔信息中转是怎么工作的？〕, the very top row of this screen — its own section so it reads as
    // a standalone link rather than part of the on/off block below it.
    case guideEntry(String)
    // SECUTG-HOOK (PLAN.md 3.48.9): 〔如何部署属于自己的信息中转〕, between the guide row and 〔添加自定义信息中转站地址〕.
    case deployEntry(String)
    case enabled(Bool)
    case hint(String)
    case autoLongText(Bool)
    case autoImageAlways(Bool)
    case readsRow(String)
    case ttlRow(String)
    case encrypt(Bool)
    case stripExif(Bool)
    case receiveHeader(String)
    case showCards(Bool)
    case askUnknown(Bool)
    case allowInsecure(Bool)
    case relaysHeader(String)
    case relayRow(Int32, RelayEndpoint)
    case addRelay(String)
    // PLAN.md 3.53 last bullet: the privacy note under 〔添加自定义信息中转站地址〕 — a custom relay is the
    // user's own server, so Si4Gram never handles or sees what goes through it.
    case addRelayNote(String)
    case trustHeader(String)
    case trustedRow(Int32, String)
    case sentRow(String)

    var section: ItemListSectionId {
        switch self {
        case .guideEntry, .deployEntry, .addRelay, .addRelayNote: return SecutgRelaySection.guide.rawValue
        case .enabled, .hint: return SecutgRelaySection.main.rawValue
        case .autoLongText, .autoImageAlways, .readsRow, .ttlRow: return SecutgRelaySection.policy.rawValue
        case .encrypt, .stripExif: return SecutgRelaySection.privacy.rawValue
        case .receiveHeader, .showCards, .askUnknown, .allowInsecure: return SecutgRelaySection.receive.rawValue
        case .relaysHeader, .relayRow: return SecutgRelaySection.relays.rawValue
        case .trustHeader, .trustedRow: return SecutgRelaySection.trust.rawValue
        case .sentRow: return SecutgRelaySection.sent.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .guideEntry: return -3
        // PLAN.md 3.48.9: 〔如何部署属于自己的信息中转〕 sits between the guide row and 〔添加自定义信息中转站地址〕.
        case .deployEntry: return -2
        // PLAN.md 3.48.8 revision: 〔添加自定义信息中转站地址〕 sits right under the guide row, in its section.
        case .addRelay: return -1
        case .addRelayNote: return 0
        case .enabled: return 1
        case .hint: return 2
        case .autoLongText: return 3
        case .autoImageAlways: return 4
        case .readsRow: return 5
        case .ttlRow: return 6
        case .encrypt: return 7
        case .stripExif: return 8
        case .receiveHeader: return 9
        case .showCards: return 10
        case .askUnknown: return 11
        case .allowInsecure: return 12
        case .relaysHeader: return relayStableIdBase - 1
        case let .relayRow(index, _): return relayStableIdBase + index
        case .trustHeader: return trustStableIdBase - 1
        case let .trustedRow(index, _): return trustStableIdBase + index
        case .sentRow: return trustStableIdBase + 10000
        }
    }

    static func ==(lhs: SecutgRelayEntry, rhs: SecutgRelayEntry) -> Bool {
        return lhs.stableId == rhs.stableId && String(describing: lhs) == String(describing: rhs)
    }

    static func <(lhs: SecutgRelayEntry, rhs: SecutgRelayEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SecutgRelayArguments
        switch self {
        case let .guideEntry(title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: arguments.openGuide)
        case let .deployEntry(title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: arguments.openDeploy)
        case let .enabled(value):
            return ItemListSwitchItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayEnabled"), value: value, sectionId: self.section, style: .blocks, updated: arguments.setEnabled)
        case let .hint(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .autoLongText(value):
            return ItemListSwitchItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayWhenLongText"), value: value, sectionId: self.section, style: .blocks, updated: arguments.setAutoLongText)
        case let .autoImageAlways(value):
            return ItemListSwitchItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayWhenImages"), value: value, sectionId: self.section, style: .blocks, updated: arguments.setAutoImageAlways)
        case let .readsRow(label):
            return ItemListDisclosureItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayReads"), label: label, sectionId: self.section, style: .blocks, action: arguments.pickReads)
        case let .ttlRow(label):
            return ItemListDisclosureItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayTtl"), label: label, sectionId: self.section, style: .blocks, action: arguments.pickTtl)
        case let .encrypt(value):
            return ItemListSwitchItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayEncrypt"), value: value, sectionId: self.section, style: .blocks, updated: arguments.setEncrypt)
        case let .stripExif(value):
            return ItemListSwitchItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayStripExif"), value: value, sectionId: self.section, style: .blocks, updated: arguments.setStripExif)
        case let .receiveHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .showCards(value):
            return ItemListSwitchItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayShowCards"), value: value, sectionId: self.section, style: .blocks, updated: arguments.setShowCards)
        case let .askUnknown(value):
            return ItemListSwitchItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayAskUnknown"), value: value, sectionId: self.section, style: .blocks, updated: arguments.setAskUnknown)
        case let .allowInsecure(value):
            return ItemListSwitchItem(presentationData: presentationData, title: SecutgL10n.string("SecutgRelayAllowInsecure"), value: value, sectionId: self.section, style: .blocks, updated: arguments.setAllowInsecure)
        case let .relaysHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .relayRow(_, relay):
            let label = relay.isDefault ? SecutgL10n.string("SecutgRelayDefault") : ""
            return ItemListDisclosureItem(presentationData: presentationData, title: relay.urlString, label: label, sectionId: self.section, style: .blocks, action: { arguments.testRelay(relay) })
        case let .addRelay(title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: arguments.addRelay)
        case let .addRelayNote(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .trustHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .trustedRow(_, host):
            return ItemListDisclosureItem(presentationData: presentationData, title: host, label: SecutgL10n.string("SecutgRelayRemove"), sectionId: self.section, style: .blocks, action: { arguments.removeTrusted(host) })
        case let .sentRow(title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: arguments.openSentItems)
        }
    }
}

private func secutgRelayEntries(config: RelayAppConfig) -> [SecutgRelayEntry] {
    var entries: [SecutgRelayEntry] = []
    let settings = config.settings
    entries.append(.guideEntry(SecutgL10n.string("SecutgRelayGuideEntry")))
    entries.append(.deployEntry(SecutgL10n.string("SecutgRelayDeployEntry")))
    entries.append(.addRelay(SecutgL10n.string("SecutgRelayAdd")))
    entries.append(.addRelayNote(SecutgL10n.string("SecutgRelayCustomPrivacyNote")))
    entries.append(.enabled(settings.enabled))
    entries.append(.hint(SecutgL10n.string("SecutgRelayHint")))
    entries.append(.autoLongText(settings.trigger.autoLongText))
    entries.append(.autoImageAlways(settings.trigger.autoImageAlways))
    entries.append(.readsRow(settings.defaultKeepPolicy.maxReads == 0 ? SecutgL10n.string("SecutgRelayReadsUnlimited") : SecutgL10n.string("SecutgRelayReadsN", ["count": "\(settings.defaultKeepPolicy.maxReads)"])))
    entries.append(.ttlRow(ttlLabel(settings.defaultKeepPolicy.ttlSeconds)))
    entries.append(.encrypt(settings.encryptContent))
    entries.append(.stripExif(settings.stripExif))
    entries.append(.receiveHeader(SecutgL10n.string("SecutgRelayReceive")))
    entries.append(.showCards(settings.showCards))
    entries.append(.askUnknown(settings.askUnknownRelay))
    entries.append(.allowInsecure(settings.allowInsecureOrLAN))
    entries.append(.relaysHeader(SecutgL10n.string("SecutgRelayMine")))
    for (index, relay) in config.relays.enumerated() {
        entries.append(.relayRow(Int32(index), relay))
    }
    if !config.trustedHosts.isEmpty {
        entries.append(.trustHeader(SecutgL10n.string("SecutgRelayTrusted")))
        for (index, trusted) in config.trustedHosts.enumerated() {
            entries.append(.trustedRow(Int32(index), trusted.urlString))
        }
    }
    entries.append(.sentRow(SecutgL10n.string("SecutgRelaySent")))
    return entries
}

private func ttlLabel(_ seconds: Int) -> String {
    switch seconds {
    case 3600: return SecutgL10n.string("SecutgRelayTtl1h")
    case 86_400: return SecutgL10n.string("SecutgRelayTtl1d")
    case 7 * 86_400: return SecutgL10n.string("SecutgRelayTtl7d")
    case 30 * 86_400: return SecutgL10n.string("SecutgRelayTtl30d")
    default: return SecutgL10n.string("SecutgRelayTtl1d")
    }
}

public enum SecutgRelaySettingsController {
    public static func controller(context: AccountContext) -> ViewController {
        let statePromise = Promise<RelayAppConfig>()
        statePromise.set(.single(SecutgRelayRuntime.shared.appState.current))

        var getControllerImpl: (() -> ViewController?)?
        func reload() {
            statePromise.set(.single(SecutgRelayRuntime.shared.appState.current))
        }
        func update(_ mutate: @escaping (inout RelayAppConfig) -> Void) {
            SecutgRelayRuntime.shared.appState.update(mutate)
            reload()
        }

        let arguments = SecutgRelayArguments(
            setEnabled: { value in update { $0.settings.enabled = value } },
            setAutoLongText: { value in update { $0.settings.trigger.autoLongText = value; $0.settings.trigger.manualOnly = !(value || $0.settings.trigger.autoImageAlways) } },
            setAutoImageAlways: { value in update { $0.settings.trigger.autoImageAlways = value; $0.settings.trigger.manualOnly = !(value || $0.settings.trigger.autoLongText) } },
            pickReads: {
                guard let controller = getControllerImpl?() else { return }
                let sheet = UIAlertController(title: SecutgL10n.string("SecutgRelayReads"), message: nil, preferredStyle: .actionSheet)
                for preset in RelayKeepPolicy.readsPresets {
                    let label = preset == 0 ? SecutgL10n.string("SecutgRelayReadsUnlimited") : SecutgL10n.string("SecutgRelayReadsN", ["count": "\(preset)"])
                    sheet.addAction(UIAlertAction(title: label, style: .default, handler: { _ in
                        update { $0.settings.defaultKeepPolicy.maxReads = preset }
                    }))
                }
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
                SecutgRelayPresentation.presentModal(sheet, { controller.view.window?.rootViewController ?? controller })
            },
            pickTtl: {
                guard let controller = getControllerImpl?() else { return }
                let sheet = UIAlertController(title: SecutgL10n.string("SecutgRelayTtl"), message: nil, preferredStyle: .actionSheet)
                for preset in RelayKeepPolicy.ttlPresets {
                    sheet.addAction(UIAlertAction(title: ttlLabel(preset), style: .default, handler: { _ in
                        update { $0.settings.defaultKeepPolicy.ttlSeconds = preset }
                    }))
                }
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
                SecutgRelayPresentation.presentModal(sheet, { controller.view.window?.rootViewController ?? controller })
            },
            setEncrypt: { value in update { $0.settings.encryptContent = value } },
            setStripExif: { value in update { $0.settings.stripExif = value } },
            setShowCards: { value in update { $0.settings.showCards = value } },
            setAskUnknown: { value in update { $0.settings.askUnknownRelay = value } },
            setAllowInsecure: { value in update { $0.settings.allowInsecureOrLAN = value } },
            addRelay: {
                // PLAN.md 3.48.8 (revision): the one place a relay is added — the top row 〔添加自定义信息中转站地址〕.
                guard let controller = getControllerImpl?() else { return }
                SecutgRelayAddFlow.present(controller: controller, onAdded: reload)
            },
            removeRelay: { id in
                update { $0.relays.removeAll(where: { $0.id == id }) }
            },
            setDefaultRelay: { id in
                update { config in
                    for index in config.relays.indices { config.relays[index].isDefault = (config.relays[index].id == id) }
                }
            },
            testRelay: { relay in
                guard let controller = getControllerImpl?() else { return }
                let sheet = UIAlertController(title: relay.urlString, message: nil, preferredStyle: .actionSheet)
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayTest"), style: .default, handler: { _ in
                    SecutgRelayRuntime.shared.client.info(baseURL: relay.urlString) { result in
                        DispatchQueue.main.async {
                            guard let controller = getControllerImpl?() else { return }
                            let message: String
                            switch result {
                            case .success(let info):
                                message = SecutgL10n.string("SecutgRelayTestOk", ["text": "\(info.maxTextBytes)", "image": "\(info.maxImageBytes)", "ttl": "\(info.maxTtlSeconds)"])
                            case .failure:
                                message = SecutgL10n.string("SecutgRelayTestFailed")
                            }
                            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default))
                            SecutgRelayPresentation.presentModal(alert, { controller.view.window?.rootViewController ?? controller })
                        }
                    }
                }))
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelaySetDefault"), style: .default, handler: { _ in
                    update { config in
                        for index in config.relays.indices { config.relays[index].isDefault = (config.relays[index].id == relay.id) }
                    }
                }))
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayRemove"), style: .destructive, handler: { _ in
                    update { $0.relays.removeAll(where: { $0.id == relay.id }) }
                }))
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
                SecutgRelayPresentation.presentModal(sheet, { controller.view.window?.rootViewController ?? controller })
            },
            removeTrusted: { host in
                update { $0.trustedHosts.removeAll(where: { $0.urlString == host }) }
            },
            openSentItems: {
                getControllerImpl?()?.push(SecutgRelaySentItemsController.controller(context: context))
            },
            openGuide: {
                getControllerImpl?()?.push(SecutgRelayGuideController.controller(context: context))
            },
            openDeploy: {
                getControllerImpl?()?.push(SecutgRelayDeployController.controller(context: context))
            }
        )

        let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
        |> map { presentationData, config -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(SecutgL10n.string("SecutgRelayTitle")),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: secutgRelayEntries(config: config),
                style: .blocks,
                animateChanges: false)
            return (controllerState, (listState, arguments))
        }

        let controller = ItemListController(context: context, state: signal)
        getControllerImpl = { [weak controller] in controller }
        return controller
    }
}
