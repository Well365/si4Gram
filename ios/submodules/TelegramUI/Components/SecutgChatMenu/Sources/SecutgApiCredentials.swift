import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import SecutgCore

/// SECUTG (PLAN.md 3.40): everyone uses their own Telegram API credentials.
///
/// - The start-up gate (3.40.2) stands over every login screen — first start, a logged-out install, adding an account
///   (2026-10-02 amendment) — when this device has no pair of its own, offering ① the guide and two fields, ② the code
///   from another device, ③ (only when the package carries a pair) the built-in pair for this run.
/// - Logged in on the built-in pair: the set-up page on every launch (`showLaunchReminderIfNeeded`), 〔现在设置〕〔稍后〕.
/// - Saving needs a restart, which iOS cannot do for itself: `SecutgApiRestartHintIos` asks the user to.
/// - A pair Telegram refuses (3.40.3) is caught on the login screen (`SecutgApiRejectionHook`) with
///   〔更改凭据〕〔恢复上一份〕.
/// - Settings → secuTG → Telegram API credentials (3.40.4) shows the source and `api_id`, never the hash, and shares
///   the user's own pair as an `A1Q:` code on the screenshot-protected quick-share page.
/// The rules are `ApiCredentialRules` in SecutgCore; the pair is stored by `UserCredentialsStore`.
public enum SecutgApiCredentialsUI {
    /// Before 2026-10-02 the one-time upgrade notice was remembered here; only the wipe still clears it.
    static let legacyUpgradeNoticeKey = "secutg.apiUpgradeNoticeShown"

    /// What this run started with (set by the app before the network stack), else read now.
    static var status: ApiCredentialStatus {
        return ApiCredentialSession.shared.status ?? ApiCredentialFiles.status()
    }

    static func syncLanguage(_ sharedContext: SharedAccountContext) {
        let strings = sharedContext.currentPresentationData.with { $0 }.strings
        SecutgL10n.currentLanguageCode = SecutgL10n.map(strings.primaryComponent.languageCode, base: strings.baseLanguageCode).rawValue
    }

    static func sourceLine(_ source: ApiCredentialRules.Source) -> String? {
        switch source {
        case .env: return SecutgL10n.string("SecutgApiSourceEnv")
        case .user: return SecutgL10n.string("SecutgApiSourceUser")
        case .bundled: return SecutgL10n.string("SecutgApiSourceBundled")
        case .none: return nil
        }
    }

    /// 3.40.6: the two lines the About block shows — the source and `api_id`, never the hash.
    public static func aboutLines() -> [String] {
        let status = self.status
        var lines: [String] = []
        if let line = sourceLine(status.source) { lines.append(line) }
        if let id = status.inUse?.apiId { lines.append(SecutgL10n.string("SecutgApiCurrentId", ["id": String(id)])) }
        return lines
    }

    // MARK: start-up gate (3.40.2)

    /// Called once a login screen is up — first start, after logging out, or adding an account: since the 2026-10-02
    /// amendment another account already logged in here no longer skips the gate. `cancelAddAccount`: the login screen
    /// is adding an account, so the gate offers the way back (it abandons that login) instead of trapping the user.
    public static func presentGateIfNeeded(sharedContext: SharedAccountContext, cancelAddAccount: (() -> Void)? = nil) {
        let status = self.status
        let view = ApiCredentialRules.gateView(ApiCredentialRules.GateInput(
            hasEnv: status.hasEnv, hasUser: status.hasUser, hasBundled: status.hasBundled,
            choseBundled: ApiCredentialSession.shared.choseBundled))
        guard case let .gate(showsBundledOption) = view, let window = sharedContext.mainWindow else { return }
        window.present(gateController(sharedContext: sharedContext, showsBundledOption: showsBundledOption, cancel: cancelAddAccount), on: .root)
    }

    private struct FormState: Equatable {
        var apiId = ""
        var apiHash = ""
        var errors: [ApiCredentialRules.FieldError] = []
    }

    /// The gate page. Also what 〔更改凭据〕 opens after a rejection.
    static func gateController(sharedContext: SharedAccountContext, showsBundledOption: Bool, cancel: (() -> Void)? = nil) -> ViewController {
        syncLanguage(sharedContext)
        let state = ValuePromise(FormState(), ignoreRepeated: true)
        let stateValue = Atomic(value: FormState())
        let update: ((inout FormState) -> Void) -> Void = { change in
            state.set(stateValue.modify { current in
                var next = current
                change(&next)
                return next
            })
        }
        var controllerRef: (() -> ViewController?)?

        let content = state.get()
        |> map { form -> (title: String, sections: [SecutgListSection]) in
            var sections: [SecutgListSection] = [SecutgListSection([.text(SecutgL10n.string("SecutgApiSetupIntro"))])]
            sections.append(contentsOf: ownPairSections(form: form))
            sections.append(SecutgListSection([.action(id: "scan", title: SecutgL10n.string("SecutgApiSetupScan"), kind: .generic)]))
            if showsBundledOption {
                sections.append(SecutgListSection([.action(id: "bundled", title: SecutgL10n.string("SecutgApiSetupUseBundled"), kind: .neutral)]))
            }
            if cancel != nil {
                sections.append(SecutgListSection([.action(id: "cancel", title: SecutgL10n.string("SecutgCancel"), kind: .neutral)]))
            }
            return (SecutgL10n.string("SecutgApiSetupTitle"), sections)
        }

        let controller = secutgListController(
            presentationData: sharedContext.currentPresentationData.with { $0 },
            updatedPresentationData: sharedContext.presentationData,
            content: content,
            tapped: { id in
                guard let controller = controllerRef?() else { return }
                switch id {
                case "site":
                    sharedContext.applicationBindings.openUrl("https://my.telegram.org")
                case "save":
                    let form = stateValue.with { $0 }
                    switch ApiCredentialRules.validate(apiId: form.apiId, apiHash: form.apiHash) {
                    case let .invalid(errors):
                        update { $0.errors = errors }
                    case let .ok(credentials):
                        update { $0.errors = [] }
                        save(credentials, over: controller)
                    }
                case "scan":
                    SecutgApiScan.present(over: controller, context: nil, completion: { [weak controller] credentials in
                        guard let controller else { return }
                        save(credentials, over: controller)
                    })
                case "bundled":
                    chooseBundled(over: controller)
                case "cancel":
                    controller.dismiss()
                    cancel?()
                default:
                    break
                }
            },
            edited: { id, text in
                update { form in
                    if id == "apiId" { form.apiId = text } else if id == "apiHash" { form.apiHash = text }
                }
            },
            hasBackButton: false)
        controllerRef = { [weak controller] in controller }
        return controller
    }

    /// ① — the four steps and the reminder (3.40.5), then the two fields, shared by the gate and the settings page.
    private static func ownPairSections(form: FormState) -> [SecutgListSection] {
        let guide = (1...4).map { "\($0). " + SecutgL10n.string("SecutgApiGuideStep\($0)") }.joined(separator: "\n")
        var fields: [SecutgListRow] = [
            .input(id: "apiId", title: SecutgL10n.string("SecutgApiIdLabel"), text: form.apiId, placeholder: "12345", isNumber: true),
            .input(id: "apiHash", title: SecutgL10n.string("SecutgApiHashLabel"), text: form.apiHash, placeholder: "0123456789abcdef…", isNumber: false),
        ]
        let errors = form.errors.map { SecutgL10n.string($0 == .id ? "SecutgApiIdInvalid" : "SecutgApiHashInvalid") }
        if !errors.isEmpty { fields.append(.text(errors.joined(separator: "\n"))) }
        return [
            SecutgListSection([.header(SecutgL10n.string("SecutgApiSetupOwn")), .text(guide), .text(SecutgL10n.string("SecutgApiGuideWarn")),
                               .action(id: "site", title: SecutgL10n.string("SecutgApiOpenSite"), kind: .generic)]),
            SecutgListSection(fields + [.action(id: "save", title: SecutgL10n.string("SecutgApiSaveRestart"), kind: .generic)]),
        ]
    }

    /// 3.40.2 item 3: write the pair, then ask for the restart iOS cannot do itself. The gate stays up: the
    /// connection in this run was built with the old pair, so logging in now would use the wrong one.
    static func save(_ credentials: ApiCredentialRules.Credentials, over controller: ViewController) {
        do {
            guard let store = UserCredentialsStore.standard() else { throw SecutgConfigError.invalidFile("no Application Support directory") }
            try store.update { $0.saving(credentials) }
            ApiCredentialSession.shared.choseBundled = false
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgApiRestartHintIos"))
        } catch {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgOperationFailed", ["error": "\(error)"]))
        }
    }

    /// ③: this run goes on with the package's pair. When the user's own pair is the one in use (the gate was opened
    /// by 〔更改凭据〕 after a rejection) it steps aside — kept as 「上一份」 — and the next start uses the package's.
    static func chooseBundled(over controller: ViewController) {
        if status.hasUser && status.source == .user {
            do {
                try UserCredentialsStore.standard()?.update { $0.settingAside() }
                ApiCredentialSession.markChoseBundledForNextLaunch()
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgApiRestartHintIos"))
            } catch {
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgOperationFailed", ["error": "\(error)"]))
            }
            return
        }
        ApiCredentialSession.shared.choseBundled = true
        controller.dismiss()
    }

    // MARK: rejected by Telegram (3.40.3)

    /// Installs the login screens' way out. Idempotent; called by the unauthorized context.
    public static func installRejectionHandler(sharedContext: SharedAccountContext) {
        SecutgApiRejectionHook.handler = { [weak sharedContext] code, controller in
            guard let sharedContext, let controller = controller as? ViewController else { return }
            presentRejection(sharedContext: sharedContext, code: code, over: controller)
        }
    }

    static func presentRejection(sharedContext: SharedAccountContext, code: String, over controller: ViewController) {
        syncLanguage(sharedContext)
        let alert = UIAlertController(title: nil, message: SecutgL10n.string("SecutgApiRejected", ["error": code]), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgApiChange"), style: .default, handler: { _ in
            let status = self.status
            sharedContext.mainWindow?.present(gateController(sharedContext: sharedContext, showsBundledOption: status.hasBundledAlternative(rejected: status.inUse)), on: .root)
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgApiRestorePrevious"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            restorePrevious(sharedContext: sharedContext, over: controller)
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    /// 「恢复上一份」 = the previous user setting; without one the package's pair (unless that is what was refused);
    /// without that the gate.
    static func restorePrevious(sharedContext: SharedAccountContext, over controller: ViewController) {
        let status = self.status
        let target = ApiCredentialRules.restoreTarget(hasPrevious: status.previous != nil,
                                                      hasBundledAlternative: status.hasBundledAlternative(rejected: status.inUse))
        do {
            switch target {
            case .previous:
                try UserCredentialsStore.standard()?.update { $0.restoringPrevious() }
            case .bundled:
                try UserCredentialsStore.standard()?.update { $0.settingAside() }
                // 3.40.3 "no previous → back to bundled": after the restart, straight to login on the package's pair
                ApiCredentialSession.markChoseBundledForNextLaunch()
            case .gate:
                sharedContext.mainWindow?.present(gateController(sharedContext: sharedContext, showsBundledOption: false), on: .root)
                return
            }
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgApiRestartHintIos"))
        } catch {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgOperationFailed", ["error": "\(error)"]))
        }
    }

    // MARK: logged in on the built-in pair (3.40.2 amendment, 2026-10-02)

    /// Every launch, while the built-in pair is in use: the set-up page as an alert with 〔现在设置〕〔稍后〕 — replacing the
    /// one-time upgrade notice. Asked once per run (`takeLaunchReminder`); 〔稍后〕 lasts for this run. 〔现在设置〕 opens the
    /// settings page, which carries the gate's guide, the two fields and the code import (saving asks for the restart).
    /// Presented with `presentSystem`, which waits until the root is in the window (an alert presented before that is
    /// silently dropped by UIKit).
    public static func showLaunchReminderIfNeeded(context: AccountContext, navigationController: NavigationController) {
        guard ApiCredentialSession.shared.takeLaunchReminder(isLoggedIn: true) else { return }
        Queue.mainQueue().after(1.0) { [weak navigationController] in
            guard let navigationController, let anchor = navigationController.viewControllers.last as? ViewController else { return }
            SecutgChatMenu.syncLanguage(context: context)
            let alert = UIAlertController(title: SecutgL10n.string("SecutgApiSetupTitle"), message: SecutgL10n.string("SecutgApiRemindText"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgApiRemindSetNow"), style: .default, handler: { [weak navigationController] _ in
                navigationController?.pushViewController(settingsController(context: context))
            }))
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgApiRemindLater"), style: .cancel))
            SecutgChatMenu.presentSystem(alert, over: anchor)
        }
    }

    // MARK: emergency wipe (3.40.6 / 3.16)

    /// The user's pair is a trace of this device. The packager's fields in the same file stay.
    public static func clearForWipe() {
        do {
            try UserCredentialsStore.standard()?.clear()
        } catch {
            NSLog("[secutg] wipe: could not clear the API credentials setting (\(error))")
        }
        UserDefaults.standard.removeObject(forKey: legacyUpgradeNoticeKey)
        UserDefaults.standard.removeObject(forKey: ApiCredentialSession.choseBundledNextLaunchKey)
        ApiCredentialShare.clearWritten()
    }

    // MARK: settings page (3.40.4)

    public static func settingsController(context: AccountContext) -> ViewController {
        SecutgChatMenu.syncLanguage(context: context)
        let state = ValuePromise(FormState(), ignoreRepeated: true)
        let stateValue = Atomic(value: FormState())
        let update: ((inout FormState) -> Void) -> Void = { change in
            state.set(stateValue.modify { current in
                var next = current
                change(&next)
                return next
            })
        }
        var controllerRef: (() -> ViewController?)?

        let content = state.get()
        |> map { form -> (title: String, sections: [SecutgListSection]) in
            // Read from disk each time: a save on this page shows as the new source only after the restart, but the
            // share button must follow the file (it shares the user's own pair, never the package's).
            let status = self.status
            let stored = UserCredentialsStore.standard()?.load()
            var current: [SecutgListRow] = []
            if let line = sourceLine(status.source) { current.append(.text(line)) }
            if let id = status.inUse?.apiId { current.append(.text(SecutgL10n.string("SecutgApiCurrentId", ["id": String(id)]))) }
            if status.source == .env { current.append(.text(SecutgL10n.string("SecutgAuditCheck8Warn"))) }
            var sections: [SecutgListSection] = [SecutgListSection(current)]
            if stored?.current != nil {
                sections.append(SecutgListSection([.action(id: "share", title: SecutgL10n.string("SecutgApiShareButton"), kind: .generic),
                                                   .text(SecutgL10n.string("SecutgApiShareWarn"))]))
            }
            sections.append(contentsOf: ownPairSections(form: form))
            sections.append(SecutgListSection([.action(id: "scan", title: SecutgL10n.string("SecutgApiSetupScan"), kind: .generic)]))
            return (SecutgL10n.string("SecutgApiSettingsTitle"), sections)
        }

        let controller = secutgListController(
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            updatedPresentationData: context.sharedContext.presentationData,
            content: content,
            tapped: { id in
                guard let controller = controllerRef?() else { return }
                switch id {
                case "site":
                    context.sharedContext.applicationBindings.openUrl("https://my.telegram.org")
                case "share":
                    guard let own = UserCredentialsStore.standard()?.load().current, let text = ApiCredentialRules.buildA1Q(own) else { return }
                    // The quick-share page: screenshot-protected, no copy button (3.40.4).
                    controller.present(SecutgQuickShareQrController(text: text, partialNote: nil, title: SecutgL10n.string("SecutgApiSettingsTitle"),
                                                                    warning: SecutgL10n.string("SecutgApiShareWarn")), in: .window(.root))
                case "save":
                    let form = stateValue.with { $0 }
                    switch ApiCredentialRules.validate(apiId: form.apiId, apiHash: form.apiHash) {
                    case let .invalid(errors):
                        update { $0.errors = errors }
                    case let .ok(credentials):
                        update { $0 = FormState() }
                        save(credentials, over: controller)
                    }
                case "scan":
                    SecutgApiScan.present(over: controller, context: context, completion: { [weak controller] credentials in
                        guard let controller else { return }
                        save(credentials, over: controller)
                        update { $0 = FormState() }
                    })
                default:
                    break
                }
            },
            edited: { id, text in
                update { form in
                    if id == "apiId" { form.apiId = text } else if id == "apiHash" { form.apiHash = text }
                }
            })
        controllerRef = { [weak controller] in controller }
        return controller
    }
}
