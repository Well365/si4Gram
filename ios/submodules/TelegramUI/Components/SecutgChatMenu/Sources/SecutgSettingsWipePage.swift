import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import SecutgCore

/// SECUTG (PLAN.md 3.52 row 4): the 擦除设置 sub-page pushed from the main settings page. Every switch, the
/// confirmation dialogs and the custom-phrase editor are unchanged from before this page existed — they still
/// live in `SecutgWipeSettings` — this file only moves their rows off the main list and onto a page of their own,
/// with the long explanatory text pushed down into this page's footer instead of sitting on the main list.
public enum SecutgWipeSettingsUI {
    public static func controller(context: AccountContext) -> ViewController {
        SecutgChatMenu.syncLanguage(context: context)

        var controllerRef: (() -> ViewController?)?
        let reloadPromise = ValuePromise<Bool>(true, ignoreRepeated: false)
        let reload: () -> Void = { reloadPromise.set(true) }

        let content = reloadPromise.get()
        |> map { _ -> (title: String, sections: [SecutgListSection]) in
            SecutgChatMenu.syncLanguage(context: context)
            let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId)
            let needsConfirmation = runtime?.wipeNeedsConfirmation ?? true
            let listensToPhrase = runtime?.wipeListensToPhrase ?? true
            let resetsAuthorizations = runtime?.wipeResetsAuthorizations ?? true

            let toggles = SecutgListSection([
                .toggle(id: "confirm", title: SecutgL10n.string("SecutgWipeConfirmToggle"), text: SecutgL10n.string(needsConfirmation ? "SecutgWipeConfirmToggleOn" : "SecutgWipeConfirmToggleOff"), value: needsConfirmation),
                .toggle(id: "listen", title: SecutgL10n.string("SecutgWipeListenToggle"), text: SecutgL10n.string(listensToPhrase ? "SecutgWipeListenToggleOn" : "SecutgWipeListenToggleOff"), value: listensToPhrase),
                .toggle(id: "resetAuth", title: SecutgL10n.string("SecutgWipeResetAuthToggle"), text: SecutgL10n.string(resetsAuthorizations ? "SecutgWipeResetAuthToggleOn" : "SecutgWipeResetAuthToggleOff"), value: resetsAuthorizations),
                .disclosure(id: "phrase", title: SecutgL10n.string("SecutgWipePhraseRow"), label: SecutgWipeSettings.customPhraseLabel(context: context)),
            ])
            // PLAN.md 3.52 row 4: "页底说明 = 原主页上的 SecutgWipeAbout + SecutgWipePhraseAbout".
            let footer = SecutgListSection([
                .text(SecutgL10n.string("SecutgWipeAbout") + "\n\n" + SecutgL10n.string("SecutgWipePhraseAbout")),
            ])
            return (SecutgL10n.string("SecutgWipeSettingsTitle"), [toggles, footer])
        }

        let controller = secutgListController(
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            updatedPresentationData: context.sharedContext.presentationData,
            content: content,
            tapped: { id in
                guard let controller = controllerRef?() else { return }
                if id == "phrase" {
                    SecutgWipeSettings.perform(.editPhrase, context: context, controller: controller, onChanged: reload)
                }
            },
            toggled: { id, value in
                guard let controller = controllerRef?() else { return }
                switch id {
                case "confirm":
                    SecutgWipeSettings.perform(.setNeedsConfirmation(value), context: context, controller: controller, onChanged: reload)
                case "listen":
                    SecutgWipeSettings.perform(.setListensToPhrase(value), context: context, controller: controller, onChanged: reload)
                case "resetAuth":
                    SecutgWipeSettings.perform(.setResetsAuthorizations(value), context: context, controller: controller, onChanged: reload)
                default:
                    break
                }
            }
        )
        controllerRef = { [weak controller] in controller }
        return controller
    }
}
