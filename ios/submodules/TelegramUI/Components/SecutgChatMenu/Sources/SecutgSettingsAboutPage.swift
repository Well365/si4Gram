import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import SecutgCore

/// SECUTG (PLAN.md 3.52 row 13): the 关于 Si4Gram sub-page — version, the sponsor entry (only when the build
/// carries one), the site, the source, and the distribution footer. "加密使用指南" is its own main-page row now
/// (table row 1), so it is not repeated here.
public enum SecutgSettingsAboutUI {
    public static func controller(context: AccountContext) -> ViewController {
        SecutgChatMenu.syncLanguage(context: context)

        var controllerRef: (() -> ViewController?)?
        let content = context.sharedContext.presentationData
        |> map { _ -> (title: String, sections: [SecutgListSection]) in
            SecutgChatMenu.syncLanguage(context: context)
            var rows: [SecutgListRow] = [
                .copyable(id: "version", title: SecutgL10n.string("SecutgSettingsVersion"), label: SecutgChatMenu.versionLine(context: context)),
                // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-05): 一句话介绍，紧跟在标题/版本号下方。
                .text(SecutgL10n.string("SecutgTagline")),
            ]
            if SecutgChatMenu.hasSponsorContent {
                rows.append(.disclosure(id: "sponsor", title: SecutgL10n.string("SecutgSponsorTitle"), label: SecutgL10n.string("SecutgSponsorHint")))
            }
            let about = SecutgAbout.current()
            if let site = about.siteURL {
                rows.append(.disclosure(id: "site", title: SecutgL10n.string("SecutgAboutSite"), label: site.absoluteString))
            }
            if let source = about.sourceURL {
                rows.append(.disclosure(id: "source", title: SecutgL10n.string("SecutgAboutSource"), label: source.absoluteString))
            }
            let linked = [about.siteURL, about.sourceURL].compactMap { $0?.absoluteString }
            let footer = about.lines
                .filter { line in !linked.contains(where: { line.contains($0) }) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (SecutgL10n.string("SecutgAboutTitle"), [SecutgListSection(rows), SecutgListSection([.text(footer)])])
        }

        let controller = secutgListController(
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            updatedPresentationData: context.sharedContext.presentationData,
            content: content,
            tapped: { id in
                guard let controller = controllerRef?() else { return }
                switch id {
                case "version":
                    SecutgChatMenu.copyVersion(context: context, controller: controller)
                case "sponsor":
                    // SECUTG-HOOK (PLAN.md 3.53): unreachable in a store build (the row above is never added),
                    // and `presentSponsor` does not even exist there.
                    #if !SECUTG_STORE_BUILD
                    SecutgChatMenu.presentSponsor(context: context, controller: controller)
                    #endif
                case "site":
                    if let url = SecutgAbout.current().siteURL?.absoluteString {
                        context.sharedContext.applicationBindings.openUrl(url)
                    }
                case "source":
                    if let url = SecutgAbout.current().sourceURL?.absoluteString {
                        context.sharedContext.applicationBindings.openUrl(url)
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
