import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import SecutgCore

/// SECUTG (PLAN.md 3.52 row 10): the 本机设备 sub-page — this device's code (copyable), its label, and 我的公钥
/// (moved here from the old 备份 group: it is what leaves this device, same as the rest of this page).
public enum SecutgSettingsDeviceUI {
    public static func controller(context: AccountContext) -> ViewController {
        SecutgChatMenu.syncLanguage(context: context)

        var controllerRef: (() -> ViewController?)?
        let reloadPromise = ValuePromise<Bool>(true, ignoreRepeated: false)
        let reload: () -> Void = { reloadPromise.set(true) }

        let content = reloadPromise.get()
        |> map { _ -> (title: String, sections: [SecutgListSection]) in
            SecutgChatMenu.syncLanguage(context: context)
            var rows: [SecutgListRow] = []
            if let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId), let ownDevice = runtime.ownDeviceIdentity() {
                let label = runtime.deviceLabel(ownDevice.deviceId) ?? ""
                rows.append(.copyable(id: "code", title: SecutgL10n.string("SecutgSettingsDeviceCodeRow", ["code": ownDevice.deviceCode]), label: label.isEmpty ? SecutgL10n.string("SecutgDeviceLabelEdit") : label))
                rows.append(.disclosure(id: "label", title: SecutgL10n.string("SecutgDeviceLabelEdit"), label: ""))
            }
            rows.append(.disclosure(id: "identity", title: SecutgL10n.string("SecutgIdentityTitle"), label: SecutgL10n.string("SecutgIdentityHint")))
            let footer = SecutgListSection([.text(SecutgL10n.string("SecutgDeviceLabelHint"))])
            return (SecutgL10n.string("SecutgSettingsDeviceRow"), [SecutgListSection(rows), footer])
        }

        let controller = secutgListController(
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            updatedPresentationData: context.sharedContext.presentationData,
            content: content,
            tapped: { id in
                guard let controller = controllerRef?() else { return }
                switch id {
                case "code":
                    guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId), let ownDevice = runtime.ownDeviceIdentity() else { return }
                    UIPasteboard.general.string = ownDevice.deviceCode
                    SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgCopied"))
                case "label":
                    guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId), let ownDevice = runtime.ownDeviceIdentity() else { return }
                    SecutgDeviceLabelDialogs.presentEditor(context: context, deviceId: ownDevice.deviceId, controller: controller, onChanged: reload)
                case "identity":
                    guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else {
                        SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgUnavailable"))
                        return
                    }
                    do {
                        // The identity is created on first use, so this row also doubles as "give me one".
                        let payload = try runtime.announceIdentity()
                        controller.present(SecutgKeyQrController(payload: payload, title: SecutgL10n.string("SecutgIdentityTitle")), in: .window(.root))
                        reload()
                    } catch {
                        SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgRegisterFailed", ["error": "\(error)"]))
                    }
                default:
                    break
                }
            }
        )
        controllerRef = { [weak controller] in controller }
        return controller
    }
}
