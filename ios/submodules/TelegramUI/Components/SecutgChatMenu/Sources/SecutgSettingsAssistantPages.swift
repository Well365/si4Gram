import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import SecutgCore

/// SECUTG (PLAN.md 3.52 row 5): the 智能助手接口 sub-page and the two pages it pushes to. iOS carries no switch of
/// its own — the assistant only runs attached to Si4Gram for Mac — so this page shows `SecutgAssistantMacOnlyNote`
/// and the two navigation rows; the switch itself belongs to the macOS copy of this screen (mirrored separately,
/// out of scope here per the task that produced this file).
public enum SecutgSettingsAssistantUI {
    public static func settingsController(context: AccountContext) -> ViewController {
        SecutgChatMenu.syncLanguage(context: context)

        var controllerRef: (() -> ViewController?)?
        let content = context.sharedContext.presentationData
        |> map { _ -> (title: String, sections: [SecutgListSection]) in
            SecutgChatMenu.syncLanguage(context: context)
            let note = SecutgListSection([.text(SecutgL10n.string("SecutgAssistantMacOnlyNote"))])
            let rows = SecutgListSection([
                .disclosure(id: "about", title: SecutgL10n.string("SecutgAssistantAboutTitle"), label: ""),
                .disclosure(id: "deploy", title: SecutgL10n.string("SecutgAssistantDeployTitle"), label: ""),
            ])
            return (SecutgL10n.string("SecutgAssistantSettingsTitle"), [note, rows])
        }

        let controller = secutgListController(
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            updatedPresentationData: context.sharedContext.presentationData,
            content: content,
            tapped: { id in
                guard let controller = controllerRef?() else { return }
                switch id {
                case "about":
                    controller.push(aboutController(context: context))
                case "deploy":
                    controller.push(deployController(context: context))
                default:
                    break
                }
            }
        )
        controllerRef = { [weak controller] in controller }
        return controller
    }

    /// 智能助手说明: pure text, three titled sections.
    private static func aboutController(context: AccountContext) -> ViewController {
        let content: Signal<(title: String, sections: [SecutgListSection]), NoError> = .single((
            SecutgL10n.string("SecutgAssistantAboutTitle"),
            [
                SecutgListSection([.text(SecutgL10n.string("SecutgAssistantAboutIntro"))]),
                SecutgListSection([.header(SecutgL10n.string("SecutgAssistantAboutKeysTitle")), .text(SecutgL10n.string("SecutgAssistantAboutKeys"))]),
                SecutgListSection([.header(SecutgL10n.string("SecutgAssistantAboutLimitsTitle")), .text(SecutgL10n.string("SecutgAssistantAboutLimits"))]),
                SecutgListSection([.header(SecutgL10n.string("SecutgAssistantAboutLocalTitle")), .text(SecutgL10n.string("SecutgAssistantAboutLocal"))]),
            ]
        ))
        return secutgListController(
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            updatedPresentationData: context.sharedContext.presentationData,
            content: content,
            tapped: { _ in }
        )
    }

    /// 智能助手服务部署: steps plus copyable commands plus the source-code row (built-in `assistant_source` only).
    private static func deployController(context: AccountContext) -> ViewController {
        var controllerRef: (() -> ViewController?)?
        let sourceURL = AssistantSourceUrl.validate(SecutgConfigHolder.shared.config?.distribution?.assistantSource)

        let content: Signal<(title: String, sections: [SecutgListSection]), NoError> = .single((
            SecutgL10n.string("SecutgAssistantDeployTitle"),
            [
                SecutgListSection([.text(SecutgL10n.string("SecutgAssistantDeployNeeds"))]),
                SecutgListSection([
                    .text(SecutgL10n.string("SecutgAssistantDeployStep1")),
                    .text(SecutgL10n.string("SecutgAssistantDeployStep2")),
                    .text(SecutgL10n.string("SecutgAssistantDeployStep3")),
                    .copyable(id: "pip", title: "python3 -m pip install --user -r requirements.txt", label: SecutgL10n.string("SecutgCopy")),
                    .text(SecutgL10n.string("SecutgAssistantDeployStep4")),
                    .copyable(id: "serve", title: "python3 -m mate serve", label: SecutgL10n.string("SecutgCopy")),
                    .text(SecutgL10n.string("SecutgAssistantDeployStep4Note")),
                    .copyable(id: "console", title: "python3 -m mate console", label: SecutgL10n.string("SecutgCopy")),
                ]),
                SecutgListSection(sourceURL != nil
                    ? [
                        // PLAN.md 3.52: 〔打开〕 on the row itself, 〔复制〕 as the row beneath it — the generic
                        // list vocabulary carries one action per row, so the two actions the spec asks for
                        // become two rows rather than one row with two buttons.
                        .disclosure(id: "sourceOpen", title: SecutgL10n.string("SecutgAssistantDeploySourceRow"), label: sourceURL!),
                        .action(id: "sourceCopy", title: SecutgL10n.string("SecutgCopy"), kind: .generic),
                      ]
                    : [.text(SecutgL10n.string("SecutgAssistantDeploySourceRow") + "\n" + SecutgL10n.string("SecutgAssistantDeploySourcePending"))]),
            ]
        ))

        let controller = secutgListController(
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            updatedPresentationData: context.sharedContext.presentationData,
            content: content,
            tapped: { id in
                guard let controller = controllerRef?() else { return }
                switch id {
                case "pip":
                    UIPasteboard.general.string = "python3 -m pip install --user -r requirements.txt"
                    SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgCopied"))
                case "serve":
                    UIPasteboard.general.string = "python3 -m mate serve"
                    SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgCopied"))
                case "console":
                    UIPasteboard.general.string = "python3 -m mate console"
                    SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgCopied"))
                case "sourceOpen":
                    if let sourceURL {
                        context.sharedContext.applicationBindings.openUrl(sourceURL)
                    }
                case "sourceCopy":
                    if let sourceURL {
                        UIPasteboard.general.string = sourceURL
                        SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgCopied"))
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
