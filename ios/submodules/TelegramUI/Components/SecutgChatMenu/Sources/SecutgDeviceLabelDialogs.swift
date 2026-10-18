import Foundation
import UIKit
import Display
import AccountContext
import TelegramCore

/// SECUTG (PLAN.md 3.25): the one editor for a device's local label, reused everywhere a device shows up —
/// the chat status row, the safety-code dialog, the "other device" header block and the settings page. Only
/// ever touches this device's own local `deviceLabels` table (PLAN.md 3.25.3/3.25.8): nothing here ever
/// leaves the device except inside an explicit PLAN.md 3.14 keyring transfer.
public enum SecutgDeviceLabelDialogs {
    /// `deviceId` must already be a well-formed device_id (16 lowercase hex chars) — callers always have one
    /// from `SecutgChatStatus` or `SecutgAccountRuntime.ownDeviceIdentity()`, never from user input.
    public static func presentEditor(context: AccountContext, deviceId: String, controller: ViewController, onChanged: @escaping () -> Void = {}) {
        SecutgChatMenu.syncLanguage(context: context)
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let code = SecutgAccountRuntime.deviceCode(forId: deviceId) ?? deviceId
        let alert = UIAlertController(
            title: SecutgL10n.string("SecutgDeviceLabelTitle"),
            message: code + "\n\n" + SecutgL10n.string("SecutgDeviceLabelHint"),
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = SecutgL10n.string("SecutgDeviceLabelEdit")
            field.text = runtime.deviceLabel(deviceId) ?? ""
            field.autocorrectionType = .yes
        }
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgSave"), style: .default, handler: { [weak alert] _ in
            let raw = alert?.textFields?.first?.text ?? ""
            try? runtime.setDeviceLabel(deviceId, raw)
            onChanged()
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    /// When both a peer device and this account's own device are on screen at once (the status row), the user
    /// picks which one to label before the editor above opens.
    public static func presentPicker(
        context: AccountContext, controller: ViewController,
        options: [(deviceId: String, title: String)], onChanged: @escaping () -> Void = {}
    ) {
        guard !options.isEmpty else { return }
        guard options.count > 1 else {
            presentEditor(context: context, deviceId: options[0].deviceId, controller: controller, onChanged: onChanged)
            return
        }
        let sheet = UIAlertController(title: SecutgL10n.string("SecutgDeviceLabelTitle"), message: nil, preferredStyle: .actionSheet)
        for option in options {
            sheet.addAction(UIAlertAction(title: option.title, style: .default, handler: { [weak controller] _ in
                guard let controller else { return }
                presentEditor(context: context, deviceId: option.deviceId, controller: controller, onChanged: onChanged)
            }))
        }
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(sheet, over: controller)
    }
}
