import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import SecutgCore

/// SECUTG (PLAN.md 3.46): Settings → secuTG → 安全体检. One page over every encrypted chat on this device: the
/// summary line, the findings risk → attention → OK, and for each a 〔去处理〕 and an 〔忽略〕 (30 days).
///
/// The checks are `SecurityAudit.run` in SecutgCore over a snapshot of states, times and counts read from this
/// account's runtime (`auditRuntimePart`) plus the few app facts below. The snapshot and the findings live in this
/// page's memory only; what is stored is the ignore list, the group-key age limit and the last backup time
/// (`SecutgLocalPrefs`, cleared by the wipe). Purely local: nothing here touches the network.
public enum SecutgAuditUI {
    private struct Page: Equatable {
        let findings: [SecurityAudit.Finding]
        let titles: [String: String]
        let groupKeyDays: Int
    }

    static func accountKey(_ context: AccountContext) -> String {
        return SecutgLocalPrefs.accountKey(context.account.peerId)
    }

    static func nowMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    /// PLAN.md 3.46.2: read once from Telegram when the page opens — never from secuTG's own state — and never
    /// sent anywhere. A failure (or taking too long) reads as "unknown": the checks then report no finding rather
    /// than a wrong one.
    private static let accountReadTimeoutSeconds: Double = 10

    /// PLAN.md 3.46 补充（2026-10-04）: `.timedOut` distinguishes "this field's own read hit the 10s wall (or
    /// failed)" from a value that just happens to be absent, so the UI can show `SecutgAuditCheckUnavailable`
    /// instead of silence.
    private enum AccountFieldRead<T> {
        case value(T)
        case timedOut
    }

    static func readAccount(context: AccountContext) -> Signal<SecurityAudit.Account, NoError> {
        let twoStep = context.engine.auth.twoStepVerificationConfiguration()
        |> take(1)
        |> map { config -> AccountFieldRead<Bool> in
            switch config {
            case .notSet: return .value(false)
            case .set: return .value(true)
            }
        }
        |> timeout(accountReadTimeoutSeconds, queue: Queue.mainQueue(), alternate: .single(.timedOut))

        let sessions = context.engine.privacy.activeSessions().state
        |> filter { !$0.isLoadingMore }
        |> take(1)
        |> map { state -> AccountFieldRead<Int> in .value(state.sessions.filter { !$0.isCurrent }.count) }
        |> timeout(accountReadTimeoutSeconds, queue: Queue.mainQueue(), alternate: .single(.timedOut))

        return combineLatest(twoStep, sessions)
        |> map { twoStepResult, sessionsResult in
            var twoStepPassword: Bool?
            var twoStepUnavailable = false
            switch twoStepResult {
            case let .value(value): twoStepPassword = value
            case .timedOut: twoStepUnavailable = true
            }
            var otherSessions: Int?
            var otherSessionsUnavailable = false
            switch sessionsResult {
            case let .value(value): otherSessions = value
            case .timedOut: otherSessionsUnavailable = true
            }
            return SecurityAudit.Account(twoStepPassword: twoStepPassword, otherSessions: otherSessions,
                                         twoStepUnavailable: twoStepUnavailable, otherSessionsUnavailable: otherSessionsUnavailable)
        }
    }

    /// The snapshot and the run. `account` is this call's fresh read of Telegram (`readAccount`); the rest answers
    /// from memory (the keyring, local prefs).
    static func findings(context: AccountContext, account: SecurityAudit.Account) -> (findings: [SecurityAudit.Finding], groupKeyDays: Int) {
        let key = accountKey(context)
        let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId)
        let groupKeyDays = SecutgLocalPrefs.auditGroupKeyMaxAgeDays(accountKey: key)
        let snapshot = SecurityAuditFacts.snapshot(
            runtime: runtime?.auditRuntimePart() ?? .empty,
            app: SecurityAuditFacts.AppPart(
                groupKeyMaxAgeDays: groupKeyDays,
                apiCredentialSource: SecutgApiCredentialsUI.status.source,
                // PLAN.md 3.37 rule 6: iOS's online gate has no switch — it is always on
                netGateEnabled: true,
                lastBackupMs: SecutgLocalPrefs.auditLastBackupMs(accountKey: key),
                ownVersion: SecutgConfigHolder.shared.config?.distribution?.version,
                // Nothing on this device records which secuTG version a contact runs: check 10 stays silent
                newestPeerVersion: nil,
                // Check 11 is macOS only
                assistant: nil,
                account: account))
        return (SecurityAudit.run(snapshot, nowMs: nowMs(), ignored: SecutgLocalPrefs.auditIgnored(accountKey: key)), groupKeyDays)
    }

    static func levelText(_ level: SecurityAudit.Level) -> String {
        switch level {
        case .risk: return SecutgL10n.string("SecutgAuditLevelRisk")
        case .warn: return SecutgL10n.string("SecutgAuditLevelWarn")
        case .ok: return SecutgL10n.string("SecutgAuditLevelOk")
        // PLAN.md 3.46 补充: no level badge for an unavailable check — its row carries the generic
        // "could not be read" sentence instead of a risk/warn/ok verdict.
        case .unavailable: return ""
        }
    }

    /// `SecutgAuditCheck<N><Risk|Warn|Ok>` with the finding's placeholders. PLAN.md 3.46 补充: `.unavailable`
    /// (check 12/13 timed out or failed) uses the one generic `SecutgAuditCheckUnavailable` sentence instead.
    static func sentence(_ finding: SecurityAudit.Finding) -> String {
        if finding.level == .unavailable { return SecutgL10n.string("SecutgAuditCheckUnavailable") }
        let suffix: String
        switch finding.level {
        case .risk: suffix = "Risk"
        case .warn: suffix = "Warn"
        case .ok: suffix = "Ok"
        case .unavailable: suffix = "" // unreachable, handled above
        }
        return SecutgL10n.string("SecutgAuditCheck\(finding.check)\(suffix)", finding.placeholders)
    }

    /// The full fetch for one page: the account read (up to the 10s timeout), then the (now off-main) local
    /// checks, then this account's chat titles. Used both by the initial `open` and by 〔重新检查〕.
    private static func pageSignal(context: AccountContext) -> Signal<Page, NoError> {
        return readAccount(context: context)
        |> mapToSignal { account -> Signal<Page, NoError> in
            // PLAN.md 3.46 补充: the local checks (keyring reads, prefs) move off the main thread so the page's
            // own work never blocks the UI while the overlay is still up.
            return Signal<SecurityAudit.Account, NoError>.single(account)
            |> runOn(Queue.concurrentDefaultQueue())
            |> map { account in findings(context: context, account: account) }
            |> mapToSignal { result -> Signal<Page, NoError> in
                let peerIds = Set(result.findings.compactMap { $0.chatId.flatMap(SecutgAccountRuntime.peerId(chatKey:)) })
                guard !peerIds.isEmpty else {
                    return .single(Page(findings: result.findings, titles: [:], groupKeyDays: result.groupKeyDays))
                }
                return context.engine.data.get(EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)))
                |> map { peers -> Page in
                    var titles: [String: String] = [:]
                    for (peerId, peer) in peers {
                        if let peer { titles[SecutgAccountRuntime.chatKey(peerId)] = peer.compactDisplayTitle }
                    }
                    return Page(findings: result.findings, titles: titles, groupKeyDays: result.groupKeyDays)
                }
            }
        }
        |> deliverOnMainQueue
    }

    /// PLAN.md 3.46 补充（2026-10-04）: the only entry point — presents the `SecutgAuditLoading` overlay at once,
    /// runs `pageSignal` in the background (bounded by `readAccount`'s own 10s timeout), then dismisses the
    /// overlay and pushes the page already filled in. Cancelling the overlay disposes the fetch and pushes
    /// nothing.
    public static func open(context: AccountContext, controller: ViewController) {
        SecutgChatMenu.syncLanguage(context: context)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let disposable = MetaDisposable()
        let overlay = SecutgAuditLoadingOverlay(theme: presentationData.theme, text: SecutgL10n.string("SecutgAuditLoading"), cancelled: {
            disposable.dispose()
        })
        controller.present(overlay, in: .window(.root))
        disposable.set((pageSignal(context: context)
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak overlay, weak controller] page in
            overlay?.dismiss()
            guard let controller else { return }
            controller.push(SecutgAuditUI.controller(context: context, initialPage: page))
        }))
    }

    /// `initialPage`, when given (from `open`), is shown at once without a second fetch; 〔重新检查〕 and the
    /// other actions below always re-fetch via `pageSignal`. Not `public`: `Page` is private, and `open` above
    /// is the only entry point other components should use.
    private static func controller(context: AccountContext, initialPage: Page? = nil) -> ViewController {
        SecutgChatMenu.syncLanguage(context: context)
        let reload = ValuePromise<Bool>(false, ignoreRepeated: false)
        var controllerRef: (() -> ViewController?)?
        var currentPage: Page?

        let page = reload.get()
        |> mapToSignal { forceReload -> Signal<Page, NoError> in
            if !forceReload, let initialPage { return .single(initialPage) }
            return pageSignal(context: context)
        }

        let content = page
        |> map { page -> (title: String, sections: [SecutgListSection]) in
            currentPage = page
            let summary = SecurityAudit.summarize(page.findings)
            var sections: [SecutgListSection] = [
                // PLAN.md 3.46.1: 〔丢了设备？〕 at the top of the page
                SecutgListSection([.action(id: "lost", title: SecutgL10n.string("SecutgLostDeviceEntry"), kind: .generic)]),
                SecutgListSection([
                    .header(SecutgL10n.string("SecutgAuditSummary", ["risk": "\(summary.risk)", "warn": "\(summary.warn)", "ok": "\(summary.ok)"])),
                    .text(SecutgL10n.string("SecutgAuditLocalNote")),
                ]),
            ]
            if page.findings.isEmpty {
                sections.append(SecutgListSection([.text(SecutgL10n.string("SecutgAuditEmpty"))]))
            }
            for level in [SecurityAudit.Level.risk, .warn, .ok, .unavailable] {
                let rows = page.findings.filter { $0.level == level }.map { finding -> SecutgListRow in
                    let prefix = levelText(level)
                    var title = prefix.isEmpty ? SecutgL10n.string("SecutgAuditCheck\(finding.check)Title") : prefix + " · " + SecutgL10n.string("SecutgAuditCheck\(finding.check)Title")
                    if let chatId = finding.chatId { title += " · " + (page.titles[chatId] ?? chatId) }
                    return .disclosure(id: "f:" + finding.id, title: title, label: sentence(finding))
                }
                if !rows.isEmpty { sections.append(SecutgListSection(rows)) }
            }
            sections.append(SecutgListSection([
                .disclosure(id: "days", title: SecutgL10n.string("SecutgAuditGroupKeyDays", ["days": "\(page.groupKeyDays)"]), label: ""),
                .action(id: "recheck", title: SecutgL10n.string("SecutgAuditRecheck"), kind: .generic),
                .text(SecutgL10n.string("SecutgAuditIgnoreHint")),
            ]))
            return (SecutgL10n.string("SecutgAuditTitle"), sections)
        }

        let controller = secutgListController(
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            updatedPresentationData: context.sharedContext.presentationData,
            content: content,
            tapped: { id in
                guard let controller = controllerRef?() else { return }
                if id == "lost" {
                    controller.push(SecutgLostDeviceUI.controller(context: context))
                } else if id == "recheck" {
                    reload.set(true)
                } else if id == "days" {
                    editGroupKeyDays(context: context, controller: controller, current: currentPage?.groupKeyDays ?? SecurityAudit.defaultGroupKeyMaxAgeDays, onChanged: { reload.set(true) })
                } else if id.hasPrefix("f:"), let finding = currentPage?.findings.first(where: { "f:" + $0.id == id }) {
                    presentFindingActions(context: context, controller: controller, finding: finding, onChanged: { reload.set(true) })
                }
            })
        controllerRef = { [weak controller] in controller }
        return controller
    }

    private static func presentFindingActions(context: AccountContext, controller: ViewController, finding: SecurityAudit.Finding, onChanged: @escaping () -> Void) {
        let sheet = UIAlertController(title: SecutgL10n.string("SecutgAuditCheck\(finding.check)Title"), message: sentence(finding), preferredStyle: .alert)
        if finding.action != .none {
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgAuditFix"), style: .default, handler: { [weak controller] _ in
                guard let controller else { return }
                fix(context: context, controller: controller, finding: finding)
            }))
        }
        // PLAN.md 3.46 补充: an unavailable (timed-out/failed) check is not something to ignore — it is not a
        // standing problem, just a read that did not complete; a recheck may simply answer it next time.
        if finding.level != .ok && finding.level != .unavailable {
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgAuditIgnore"), style: .default, handler: { _ in
                let key = accountKey(context)
                SecutgLocalPrefs.setAuditIgnored(SecurityAudit.ignoring(SecutgLocalPrefs.auditIgnored(accountKey: key), id: finding.id, nowMs: nowMs()), accountKey: key)
                onChanged()
            }))
        }
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(sheet, over: controller)
    }

    /// 〔去处理〕: the chat for per-chat findings (then its safety-code page or lock menu when the finding names one), the secuTG
    /// settings page for the switches it holds, the export for a backup, the API page for check 8.
    private static func fix(context: AccountContext, controller: ViewController, finding: SecurityAudit.Finding) {
        switch finding.action {
        case .openChat, .openSafetyCode, .openLockMenu:
            guard let chatId = finding.chatId, let peerId = SecutgAccountRuntime.peerId(chatKey: chatId),
                  let navigationController = controller.navigationController as? NavigationController else { return }
            let action = finding.action
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).start(next: { [weak navigationController] peer in
                guard let peer, let navigationController else { return }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
                guard action != .openChat else { return }
                // 3.46's table: check 2 opens the chat's safety-code page, check 4 its lock menu (as Web and Android) —
                // once the chat is on screen, over it
                Queue.mainQueue().after(0.6) { [weak navigationController] in
                    guard let chat = navigationController?.topViewController as? ViewController else { return }
                    if action == .openSafetyCode {
                        SecutgChatMenu.presentSafetyCode(context: context, peerId: peerId, controller: chat)
                    } else {
                        SecutgChatMenu.presentSheet(context: context, peerId: peerId, controller: chat, sourceView: chat.view)
                    }
                }
            })
        case .openLocalCiphertext, .openWipeSettings:
            controller.push(secutgSettingsController(context: context))
        case .openBackup:
            SecutgTransfer.presentExport(context: context, controller: controller, scope: .all)
        case .openApiCredentials:
            controller.push(SecutgApiCredentialsUI.settingsController(context: context))
        case .openTwoStep:
            SecutgTwoStepNav.open(context: context, controller: controller)
        case .openSessions:
            controller.push(SecutgLostDeviceUI.controller(context: context))
        case .openAssistant, .none:
            break
        }
    }

    private static func editGroupKeyDays(context: AccountContext, controller: ViewController, current: Int, onChanged: @escaping () -> Void) {
        let alert = UIAlertController(title: SecutgL10n.string("SecutgAuditCheck3Title"), message: SecutgL10n.string("SecutgAuditGroupKeyDays", ["days": "\(current)"]), preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.text = "\(current)"
        }
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgSave"), style: .default, handler: { [weak alert] _ in
            guard let text = alert?.textFields?.first?.text, let days = Int(text.trimmingCharacters(in: .whitespaces)), days > 0 else { return }
            SecutgLocalPrefs.setAuditGroupKeyMaxAgeDays(days, accountKey: accountKey(context))
            onChanged()
        }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }
}
