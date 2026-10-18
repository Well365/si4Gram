import Foundation
import UIKit
import Display
import TelegramCore
import SecutgCore

/// PLAN.md 3.48.4 「我的中转 →〔添加中转〕」: address + optional upload token, 〔测试连接〕= `GET /v1/info`, only
/// saved on success. Pulled out of `SecutgRelaySettingsController` (where it used to be an inline closure) so the
/// relay guide page (PLAN.md 3.48.8) can open the exact same flow from its own 〔添加中转〕button instead of growing
/// a second copy of this dialog.
public enum SecutgRelayAddFlow {
    public static func present(controller: ViewController, onAdded: (() -> Void)? = nil) {
        // PLAN.md 3.53 last bullet: the same privacy note the settings page shows under this row, repeated here
        // because this dialog is also reachable from the relay guide page's own 〔添加中转〕 button.
        let sheet = UIAlertController(title: SecutgL10n.string("SecutgRelayAdd"), message: SecutgL10n.string("SecutgRelayCustomPrivacyNote"), preferredStyle: .alert)
        sheet.addTextField(configurationHandler: { $0.placeholder = SecutgL10n.string("SecutgRelayAddress") })
        sheet.addTextField(configurationHandler: { $0.placeholder = SecutgL10n.string("SecutgRelayToken"); $0.isSecureTextEntry = true })
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayTest"), style: .default, handler: { _ in
            guard let raw = sheet.textFields?.first?.text, let normalized = RelayHost.normalize(raw) else { return }
            let token = sheet.textFields?.last?.text?.isEmpty == false ? sheet.textFields?.last?.text : nil
            SecutgRelayRuntime.shared.client.info(baseURL: normalized) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        SecutgRelayRuntime.shared.appState.update { config in
                            let isFirst = config.relays.isEmpty
                            config.relays.append(RelayEndpoint(urlString: normalized, token: token, isDefault: isFirst))
                        }
                        onAdded?()
                    case .failure:
                        let alert = UIAlertController(title: nil, message: SecutgL10n.string("SecutgRelayTestFailed"), preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default))
                        SecutgRelayPresentation.presentModal(alert, { controller.view.window?.rootViewController ?? controller })
                    }
                }
            }
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
        SecutgRelayPresentation.presentModal(sheet, { controller.view.window?.rootViewController ?? controller })
    }
}
