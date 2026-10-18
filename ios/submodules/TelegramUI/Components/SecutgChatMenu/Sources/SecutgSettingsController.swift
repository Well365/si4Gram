import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import ItemListPeerActionItem
import LocalizedPeerData
import SecutgCore
import SecutgRelay // SECUTG-HOOK (PLAN.md 3.48.0 hook ③): one-directional only — SecutgRelay never imports this component back

/// SECUTG: the secuTG settings screen (PLAN.md 3.29.1 rule 3 / 3.52).
///
/// PLAN.md 3.52 regrouped what used to be one long, flat list into this main page plus a handful of pushed
/// sub-pages (`SecutgSettingsWipePage.swift`, `SecutgSettingsAssistantPages.swift`,
/// `SecutgSettingsDevicePage.swift`, `SecutgSettingsChatsPage.swift`, `SecutgSettingsAboutPage.swift`). Every row's
/// action, confirmation dialog and switch read/write is exactly what it was before this reorganisation — only the
/// row's *position* and whether its long explanation sits on this page or a sub-page's footer changed.
///
/// Every preference on this page lives in the keyring, not in Telegram's preferences, so nothing will wake the
/// list when one changes — `reload` is the screen's own "redraw yourself".
private final class SecutgSettingsArguments {
    let wipe: () -> Void
    let setLocalCiphertext: (Bool) -> Void
    let setFoldsUndecryptable: (Bool) -> Void
    let openGuide: () -> Void
    let openApiCredentials: () -> Void
    let openWipeSettings: () -> Void
    let openAssistantSettings: () -> Void
    let openRelay: () -> Void
    let openAudit: () -> Void
    let openDevice: () -> Void
    let exportKeyring: () -> Void
    let importKeyring: () -> Void
    let openChats: () -> Void
    let openAbout: () -> Void

    init(
        wipe: @escaping () -> Void,
        setLocalCiphertext: @escaping (Bool) -> Void,
        setFoldsUndecryptable: @escaping (Bool) -> Void,
        openGuide: @escaping () -> Void,
        openApiCredentials: @escaping () -> Void,
        openWipeSettings: @escaping () -> Void,
        openAssistantSettings: @escaping () -> Void,
        openRelay: @escaping () -> Void,
        openAudit: @escaping () -> Void,
        openDevice: @escaping () -> Void,
        exportKeyring: @escaping () -> Void,
        importKeyring: @escaping () -> Void,
        openChats: @escaping () -> Void,
        openAbout: @escaping () -> Void
    ) {
        self.wipe = wipe
        self.setLocalCiphertext = setLocalCiphertext
        self.setFoldsUndecryptable = setFoldsUndecryptable
        self.openGuide = openGuide
        self.openApiCredentials = openApiCredentials
        self.openWipeSettings = openWipeSettings
        self.openAssistantSettings = openAssistantSettings
        self.openRelay = openRelay
        self.openAudit = openAudit
        self.openDevice = openDevice
        self.exportKeyring = exportKeyring
        self.importKeyring = importKeyring
        self.openChats = openChats
        self.openAbout = openAbout
    }
}

/// PLAN.md 3.52: five titled groups below the two headerless top rows, in this fixed order.
private enum SecutgSettingsSection: Int32 {
    case top        // 加密使用指南, 专属应用身份 — no header
    case urgent     // ① 紧急：紧急擦除, 擦除设置
    case services   // 智能助手接口, 信息中转 — no header
    case check      // ② 检查：安全体检
    case device     // ③ 本机：不落盘, 折叠, 本机设备 + one footer line
    case backup     // ④ 备份：导出, 导入
    case chats      // 已加密的聊天 — no header
    case help       // ⑤ 帮助与关于：关于 Si4Gram
}

private enum SecutgSettingsEntry: ItemListNodeEntry {
    case guide(String)
    case apiCredentials(String, String)

    case urgentHeader(String)
    case wipeAction
    case wipeHint(String)
    case wipeSettings(String)
    case assistantSettings(String)
    case relay(String, String)

    case checkHeader(String)
    case audit(String, String)

    case deviceHeader(String)
    case localCiphertext(Bool)
    case localCiphertextFooter(String)
    case fold(Bool)
    case foldFooter(String)
    case device(String, String)

    case backupHeader(String)
    case exportAll(String, String)
    case importKeyring(String)
    case chats(String, String)

    case helpHeader(String)
    case about(String, String)

    var section: ItemListSectionId {
        switch self {
        case .guide, .apiCredentials:
            return SecutgSettingsSection.top.rawValue
        case .urgentHeader, .wipeAction, .wipeHint, .wipeSettings:
            return SecutgSettingsSection.urgent.rawValue
        case .assistantSettings, .relay:
            return SecutgSettingsSection.services.rawValue
        case .checkHeader, .audit:
            return SecutgSettingsSection.check.rawValue
        case .deviceHeader, .localCiphertext, .localCiphertextFooter, .fold, .foldFooter, .device:
            return SecutgSettingsSection.device.rawValue
        case .backupHeader, .exportAll, .importKeyring:
            return SecutgSettingsSection.backup.rawValue
        case .chats:
            return SecutgSettingsSection.chats.rawValue
        case .helpHeader, .about:
            return SecutgSettingsSection.help.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .guide: return 0
        case .apiCredentials: return 1
        case .urgentHeader: return 2
        case .wipeAction: return 3
        case .wipeHint: return 4
        case .wipeSettings: return 5
        case .assistantSettings: return 6
        case .relay: return 7
        case .checkHeader: return 8
        case .audit: return 9
        case .deviceHeader: return 10
        case .localCiphertext: return 11
        case .fold: return 12
        case .foldFooter: return 13
        case .device: return 14
        case .localCiphertextFooter: return 15
        case .backupHeader: return 16
        case .exportAll: return 17
        case .importKeyring: return 18
        case .chats: return 19
        case .helpHeader: return 20
        case .about: return 21
        }
    }

    static func <(lhs: SecutgSettingsEntry, rhs: SecutgSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SecutgSettingsArguments
        switch self {
        case let .guide(title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgGuide, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openGuide()
            })
        case let .apiCredentials(title, hint):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgDevice, title: title, label: hint, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.openApiCredentials()
            })
        case let .urgentHeader(text), let .checkHeader(text), let .deviceHeader(text), let .backupHeader(text), let .helpHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case .wipeAction:
            // PLAN.md 3.16: the one control that has to be findable without hunting, by someone who is not calm.
            return ItemListPeerActionItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgWipe, title: SecutgL10n.string("SecutgWipeTitle"), sectionId: self.section, height: .generic, color: .destructive, action: {
                arguments.wipe()
            })
        case let .wipeHint(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .wipeSettings(subtitle):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgWipeConfirm, title: SecutgL10n.string("SecutgWipeSettingsTitle"), label: subtitle, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.openWipeSettings()
            })
        case let .assistantSettings(subtitle):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: SecutgL10n.string("SecutgAssistantSettingsTitle"), label: subtitle, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.openAssistantSettings()
            })
        case let .relay(title, hint):
            // SECUTG-HOOK (PLAN.md 3.48.0 hook ③)
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgLink, title: title, label: hint, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.openRelay()
            })
        case let .audit(title, hint):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgLocalCiphertext, title: title, label: hint, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.openAudit()
            })
        case let .localCiphertext(value):
            // PLAN.md 3.52 row 8: the main page no longer shows this switch's own on/off subtitle.
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgLocalCiphertext, title: SecutgL10n.string("SecutgLocalCiphertext"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setLocalCiphertext(value)
            })
        case let .localCiphertextFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .fold(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgFilterUndecryptable, title: SecutgL10n.string("SecutgFilterUndecryptable"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setFoldsUndecryptable(value)
            })
        case let .foldFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .device(title, subtitle):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgDevice, title: title, label: subtitle, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.openDevice()
            })
        case let .exportAll(title, hint):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgExport, title: title, label: hint, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.exportKeyring()
            })
        case let .importKeyring(title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgImport, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.importKeyring()
            })
        case let .chats(title, subtitle):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgChatEncrypted, title: title, label: subtitle, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.openChats()
            })
        case let .about(title, subtitle):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.secutgVersion, title: title, label: subtitle, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.openAbout()
            })
        }
    }
}

private func secutgSettingsEntries(context: AccountContext, keyedChatCount: Int) -> [SecutgSettingsEntry] {
    var entries: [SecutgSettingsEntry] = []
    let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId)

    // Top, no header.
    entries.append(.guide(SecutgL10n.string("SecutgGuideTitle")))
    let apiSource = SecutgApiCredentialsUI.status.source
    let apiSubtitle = SecutgSettingsSubtitles.apiIdentitySubtitleKey(source: apiSource).map { SecutgL10n.string($0) } ?? ""
    entries.append(.apiCredentials(SecutgL10n.string("SecutgApiSettingsTitle"), apiSubtitle))

    // ① 紧急.
    entries.append(.urgentHeader(SecutgL10n.string("SecutgSettingsSectionUrgent")))
    entries.append(.wipeAction)
    entries.append(.wipeHint(SecutgL10n.string("SecutgWipeHint")))
    let needsConfirmation = runtime?.wipeNeedsConfirmation ?? true
    let listensToPhrase = runtime?.wipeListensToPhrase ?? true
    let resetsAuthorizations = runtime?.wipeResetsAuthorizations ?? true
    let hasCustomPhrase = !(runtime?.wipeCustomPhrase ?? "").isEmpty
    let wipeLabelKeys = SecutgSettingsSubtitles.wipeSettingsActiveLabelKeys(needsConfirmation: needsConfirmation, listensToPhrase: listensToPhrase, resetsAuthorizations: resetsAuthorizations, hasCustomPhrase: hasCustomPhrase)
    let wipeSubtitle = wipeLabelKeys.isEmpty ? SecutgL10n.string("SecutgWipeSettingsAllOff") : wipeLabelKeys.map { SecutgL10n.string($0) }.joined(separator: " · ")
    entries.append(.wipeSettings(wipeSubtitle))
    // PLAN.md 3.52 row 5: iOS carries no switch of its own (the assistant only runs attached to the Mac build).
    // PLAN.md 3.52 (用户 2026-10-03): 智能助手接口 is Mac-only, so this client does not offer the row at all.
    entries.append(.relay(SecutgL10n.string("SecutgRelayTitle"), ""))

    // ② 检查.
    entries.append(.checkHeader(SecutgL10n.string("SecutgSettingsSectionCheck")))
    entries.append(.audit(SecutgL10n.string("SecutgAuditTitle"), SecutgL10n.string("SecutgAuditHint")))

    // ③ 本机.
    entries.append(.deviceHeader(SecutgL10n.string("SecutgSettingsSectionDevice")))
    let keepsCiphertext = runtime?.localCiphertext ?? true
    entries.append(.localCiphertext(keepsCiphertext))
    entries.append(.fold(SecutgFoldState.shared.isEnabled(accountPeerId: context.account.peerId)))
    if let runtime = runtime {
        // 我的公钥 lives on this page, so the row is offered whenever there is a runtime; the code only when known.
        let deviceSubtitle = runtime.ownDeviceIdentity().map { SecutgL10n.string("SecutgSettingsDeviceCodeShort", ["code": $0.deviceCode]) } ?? ""
        entries.append(.device(SecutgL10n.string("SecutgSettingsDeviceRow"), deviceSubtitle))
    }
    // PLAN.md 3.52 (用户 2026-10-03「加」): one footer line under the group — already-stored plaintext stays.
    entries.append(.localCiphertextFooter(SecutgL10n.string("SecutgLocalCiphertextNote")))

    // ④ 备份.
    entries.append(.backupHeader(SecutgL10n.string("SecutgSettingsSectionBackup")))
    entries.append(.exportAll(SecutgL10n.string("SecutgMenuExportAll"), ""))
    entries.append(.importKeyring(SecutgL10n.string("SecutgMenuImportKeyring")))
    entries.append(.chats(SecutgL10n.string("SecutgSettingsChats"), SecutgL10n.string("SecutgSettingsChatsCount", ["count": "\(keyedChatCount)"])))

    // ⑤ 帮助与关于.
    entries.append(.helpHeader(SecutgL10n.string("SecutgSettingsSectionHelp")))
    entries.append(.about(SecutgL10n.string("SecutgAboutTitle"), SecutgAbout.shortVersionLine()))

    return entries
}

public func secutgSettingsController(context: AccountContext) -> ViewController {
    SecutgChatMenu.syncLanguage(context: context)

    var getControllerImpl: (() -> ViewController?)?
    // Nothing subscribes to keyring-backed preferences, so the screen is redrawn by hand.
    let reloadPromise = ValuePromise<Bool>(true, ignoreRepeated: false)
    let reload: () -> Void = { reloadPromise.set(true) }

    let arguments = SecutgSettingsArguments(
        wipe: {
            guard let controller = getControllerImpl?() else { return }
            SecutgWipeSettings.perform(.wipeNow, context: context, controller: controller, onChanged: reload)
        },
        setLocalCiphertext: { value in
            SecutgHookRegistry.shared.runtime(for: context.account.peerId)?.setLocalCiphertext(value)
            reload()
        },
        setFoldsUndecryptable: { value in
            SecutgFoldState.shared.setEnabled(value, accountPeerId: context.account.peerId)
            reload()
        },
        openGuide: {
            guard let controller = getControllerImpl?() else { return }
            SecutgChatMenu.presentGuide(context: context, controller: controller)
        },
        openApiCredentials: {
            getControllerImpl?()?.push(SecutgApiCredentialsUI.settingsController(context: context))
        },
        openWipeSettings: {
            getControllerImpl?()?.push(SecutgWipeSettingsUI.controller(context: context))
        },
        openAssistantSettings: {
            getControllerImpl?()?.push(SecutgSettingsAssistantUI.settingsController(context: context))
        },
        openRelay: {
            // SECUTG-HOOK (PLAN.md 3.48.0 hook ③)
            guard let controller = getControllerImpl?() else { return }
            SecutgRelayMenu.pushSettingsController(context: context, controller: controller)
        },
        openAudit: {
            // PLAN.md 3.46 补充: show the loading overlay at once instead of pushing a page that sits blank
            // until the two network reads (two-step verification, other sessions) come back.
            guard let controller = getControllerImpl?() else { return }
            SecutgAuditUI.open(context: context, controller: controller)
        },
        openDevice: {
            getControllerImpl?()?.push(SecutgSettingsDeviceUI.controller(context: context))
        },
        exportKeyring: {
            guard let controller = getControllerImpl?() else { return }
            SecutgTransfer.presentExport(context: context, controller: controller, scope: .all)
        },
        importKeyring: {
            guard let controller = getControllerImpl?() else { return }
            SecutgTransfer.presentImport(context: context, controller: controller)
        },
        openChats: {
            getControllerImpl?()?.push(SecutgSettingsChatsUI.controller(context: context))
        },
        openAbout: {
            getControllerImpl?()?.push(SecutgSettingsAboutUI.controller(context: context))
        }
    )

    // The keyed-chat count hangs off `reload` too, so an import made from this page's own transfer block shows
    // up in the count below it instead of waiting for the screen to be opened again.
    let keyedChatCount = reloadPromise.get()
    |> mapToSignal { _ -> Signal<Int, NoError> in
        return secutgKeyedChats(context: context) |> map { $0.count }
    }

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        keyedChatCount
    )
    |> map { presentationData, keyedChatCount -> (ItemListControllerState, (ItemListNodeState, Any)) in
        // The language table is keyed off the Telegram language, which the user can change while this screen
        // is open; re-syncing here costs nothing and keeps every row on the same pack.
        SecutgChatMenu.syncLanguage(context: context)

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(SecutgL10n.string("SecutgSettingsTitle")),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: secutgSettingsEntries(context: context, keyedChatCount: keyedChatCount),
            style: .blocks,
            animateChanges: false)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    getControllerImpl = { [weak controller] in controller }
    return controller
}
