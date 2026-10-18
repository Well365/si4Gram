import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ItemListUI
import LocalizedPeerData
import SecutgCore

/// SECUTG (PLAN.md 3.46.2 §2): 〔丢了设备？〕, opened from the top of the security check-up. Three steps, each done
/// in the page itself:
///
///   1. end the lost device's session — the signed-in devices are listed right here (current device first,
///      unselectable), each other one 〔结束〕 with a confirmation, or 〔结束除本机外的所有设备〕 for all of them;
///   2. two-step verification — read once when the page opens, 〔去设置〕 opens Telegram's own settings;
///   3. the thorough fix is a new account — text only, plus (if not ready to do that yet) the chats this device
///      imported by QR or showed a code for (`LostDeviceGuide.affectedChats`, unchanged from 3.46.1), each row
///      opening the chat to re-pair, and one line about encrypted groups.
///
/// The device list and the two-step status are read once from Telegram when the page opens (and again on every
/// 〔重试〕 / after ending a session) — the one place in 3.46.2 where this page is not purely local. Nothing
/// secuTG-specific is ever sent.
public enum SecutgLostDeviceUI {
    enum SessionsState: Equatable {
        case loading
        case failed
        case loaded([RecentAccountSession])
    }

    private struct Page: Equatable {
        let sessions: SessionsState
        let twoStepPassword: Bool?
        let shared: [LostDeviceGuide.AffectedChat]
        let titles: [String: String]
    }

    private static let sessionsTimeoutSeconds: Double = 15
    private static let twoStepTimeoutSeconds: Double = 10

    static func affectedChats(context: AccountContext) -> [LostDeviceGuide.AffectedChat] {
        let ownUserId = SecutgAccountRuntime.userId(context.account.peerId)
        let imported = LostDeviceGuide.importedChatIds(v2: V2RuntimeRegistry.shared.runtime(for: ownUserId))
        let shown = SecutgLocalPrefs.lostDeviceShownCodes(accountKey: SecutgLocalPrefs.accountKey(context.account.peerId))
        return LostDeviceGuide.affectedChats(importedChatIds: imported, shownCodes: shown, ownUserId: ownUserId)
    }

    private static func deviceLabel(_ session: RecentAccountSession) -> String {
        var parts: [String] = []
        if !session.deviceModel.isEmpty { parts.append(session.deviceModel) }
        if !session.appName.isEmpty { parts.append(session.appName) }
        let place = !session.region.isEmpty ? session.region : session.country
        if !place.isEmpty { parts.append(place) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    public static func controller(context: AccountContext) -> ViewController {
        SecutgChatMenu.syncLanguage(context: context)
        var controllerRef: (() -> ViewController?)?
        var currentPage: Page?

        let sessionsContext = context.engine.privacy.activeSessions()
        let retrySessions = ValuePromise<Bool>(true, ignoreRepeated: false)
        let sessionsState: Signal<SessionsState, NoError> = retrySessions.get()
        |> mapToSignal { _ -> Signal<SessionsState, NoError> in
            sessionsContext.loadMore()
            return sessionsContext.state
            |> filter { !$0.isLoadingMore }
            |> take(1)
            |> map { SessionsState.loaded($0.sessions) }
            |> timeout(sessionsTimeoutSeconds, queue: Queue.mainQueue(), alternate: .single(.failed))
        }

        let twoStep: Signal<Bool?, NoError> = context.engine.auth.twoStepVerificationConfiguration()
        |> take(1)
        |> map { config -> Bool? in
            switch config {
            case .notSet: return false
            case .set: return true
            }
        }
        |> timeout(twoStepTimeoutSeconds, queue: Queue.mainQueue(), alternate: .single(nil))

        let shared = affectedChats(context: context)
        let sharedTitles: Signal<[String: String], NoError> = {
            let peerIds = shared.compactMap { SecutgAccountRuntime.peerId(chatKey: $0.chatId) }
            guard !peerIds.isEmpty else { return .single([:]) }
            return context.engine.data.get(EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)))
            |> map { peers -> [String: String] in
                var titles: [String: String] = [:]
                for (peerId, peer) in peers {
                    if let peer { titles[SecutgAccountRuntime.chatKey(peerId)] = peer.compactDisplayTitle }
                }
                return titles
            }
        }()

        let page = combineLatest(sessionsState, twoStep, sharedTitles)
        |> map { sessionsState, twoStepPassword, titles in
            Page(sessions: sessionsState, twoStepPassword: twoStepPassword, shared: shared, titles: titles)
        }
        |> deliverOnMainQueue

        let content = page
        |> map { page -> (title: String, sections: [SecutgListSection]) in
            currentPage = page
            var sections: [SecutgListSection] = [SecutgListSection([.text(SecutgL10n.string("SecutgLostDeviceIntro"))])]

            // Step 1: end the lost device's session, in the page.
            var step1: [SecutgListRow] = [.text(SecutgL10n.string("SecutgLostDeviceStep1"))]
            switch page.sessions {
            case .loading:
                step1.append(.text(SecutgL10n.string("SecutgLostDeviceSessionsLoading")))
            case .failed:
                step1.append(.text(SecutgL10n.string("SecutgLostDeviceSessionsFailed")))
                step1.append(.action(id: "retry", title: SecutgL10n.string("SecutgLostDeviceRetry"), kind: .generic))
            case let .loaded(sessions):
                if let current = sessions.first(where: { $0.isCurrent }) {
                    step1.append(.text("\(SecutgL10n.string("SecutgLostDeviceThisDevice")): \(deviceLabel(current))"))
                }
                let others = sessions.filter { !$0.isCurrent }
                if others.isEmpty {
                    step1.append(.text(SecutgL10n.string("SecutgLostDeviceNoOthers")))
                } else {
                    for session in others {
                        let label = SecutgL10n.string("SecutgLostDeviceLastActive", ["time": SecutgTransfer.dateText(Int64(session.activityDate))])
                        step1.append(.disclosure(id: "end:\(session.hash)", title: deviceLabel(session), label: label))
                    }
                    step1.append(.action(id: "endAll", title: SecutgL10n.string("SecutgLostDeviceEndAll"), kind: .destructive))
                }
            }
            step1.append(.text(SecutgL10n.string("SecutgLostDeviceOtherAccounts")))
            sections.append(SecutgListSection(step1))

            // Step 2: two-step verification.
            let twoStepLabel: String
            switch page.twoStepPassword {
            case .some(true): twoStepLabel = SecutgL10n.string("SecutgLostDeviceTwoStepOn")
            case .some(false): twoStepLabel = SecutgL10n.string("SecutgLostDeviceTwoStepOff")
            case nil: twoStepLabel = SecutgL10n.string("SecutgLostDeviceTwoStepUnknown")
            }
            sections.append(SecutgListSection([
                .text(SecutgL10n.string("SecutgLostDeviceStep2")),
                .disclosure(id: "twoStep", title: twoStepLabel, label: page.twoStepPassword == true ? "" : SecutgL10n.string("SecutgLostDeviceTwoStepSet")),
            ]))

            // Step 3: the thorough fix is a new account; meanwhile, the chats to re-pair.
            var step3: [SecutgListRow] = [.text(SecutgL10n.string("SecutgLostDeviceStep3")), .header(SecutgL10n.string("SecutgLostDeviceSharedChats"))]
            if page.shared.isEmpty {
                step3.append(.text(SecutgL10n.string("SecutgLostDeviceStep3Empty")))
            } else {
                for row in page.shared {
                    let label = row.shownAtMs.map { SecutgTransfer.dateText($0 / 1000) } ?? ""
                    step3.append(.disclosure(id: "chat:" + row.chatId, title: page.titles[row.chatId] ?? row.chatId, label: label))
                }
            }
            step3.append(.text(SecutgL10n.string("SecutgLostDeviceGroups")))
            sections.append(SecutgListSection(step3))

            return (SecutgL10n.string("SecutgLostDeviceTitle"), sections)
        }

        let controller = secutgListController(
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            updatedPresentationData: context.sharedContext.presentationData,
            content: content,
            tapped: { id in
                guard let controller = controllerRef?() else { return }
                if id == "retry" {
                    retrySessions.set(true)
                } else if id == "endAll" {
                    guard case let .loaded(sessions) = currentPage?.sessions else { return }
                    let others = sessions.filter { !$0.isCurrent }
                    guard !others.isEmpty else { return }
                    confirmEndAll(controller: controller, sessionsContext: sessionsContext, count: others.count, onChanged: { retrySessions.set(true) })
                } else if id == "twoStep" {
                    SecutgTwoStepNav.open(context: context, controller: controller)
                } else if id.hasPrefix("end:") {
                    guard case let .loaded(sessions) = currentPage?.sessions, let hash = Int64(id.dropFirst(4)),
                          let session = sessions.first(where: { $0.hash == hash }) else { return }
                    confirmEnd(controller: controller, sessionsContext: sessionsContext, session: session, onChanged: { retrySessions.set(true) })
                } else if id.hasPrefix("chat:") {
                    guard let peerId = SecutgAccountRuntime.peerId(chatKey: String(id.dropFirst(5))) else { return }
                    openChat(context: context, controller: controller, peerId: peerId)
                }
            })
        controllerRef = { [weak controller] in controller }
        return controller
    }

    // MARK: step 1 actions

    private static func terminateErrorMessage(_ error: TerminateSessionError) -> String {
        switch error {
        case .freshReset: return SecutgL10n.string("SecutgLostDeviceTooFresh")
        case .generic: return SecutgL10n.string("SecutgLostDeviceEndFailed")
        }
    }

    private static func confirmEnd(controller: ViewController, sessionsContext: ActiveSessionsContext,
                                   session: RecentAccountSession, onChanged: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: SecutgL10n.string("SecutgLostDeviceEndConfirm", ["device": deviceLabel(session)]), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgLostDeviceEnd"), style: .destructive, handler: { [weak controller] _ in
            let _ = (sessionsContext.remove(hash: session.hash) |> deliverOnMainQueue).start(error: { error in
                guard let controller else { return }
                SecutgChatMenu.toast(controller, terminateErrorMessage(error))
            }, completed: { [weak controller] in
                guard let controller else { return }
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgLostDeviceEndDone"))
                onChanged()
            })
        }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    private static func confirmEndAll(controller: ViewController, sessionsContext: ActiveSessionsContext,
                                      count: Int, onChanged: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: SecutgL10n.string("SecutgLostDeviceEndAllConfirm", ["count": "\(count)"]), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgLostDeviceEndAll"), style: .destructive, handler: { [weak controller] _ in
            let _ = (sessionsContext.removeOther() |> deliverOnMainQueue).start(error: { error in
                guard let controller else { return }
                SecutgChatMenu.toast(controller, terminateErrorMessage(error))
            }, completed: { [weak controller] in
                guard let controller else { return }
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgLostDeviceEndDone"))
                onChanged()
            })
        }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    private static func openChat(context: AccountContext, controller: ViewController, peerId: PeerId) {
        guard let navigationController = controller.navigationController as? NavigationController else { return }
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> deliverOnMainQueue).start(next: { [weak navigationController] peer in
            guard let peer, let navigationController else { return }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
        })
    }
}

/// SECUTG (PLAN.md 3.46.2): opens Telegram's own two-step verification screens without SecutgChatMenu depending on
/// SettingsUI (SettingsUI → … → ChatListUI/PeerInfoUI → SecutgChatMenu would be a cycle). Not set → the setup intro;
/// set → Privacy and Security, whose two-step row asks for the password first. Both come from SharedAccountContext.
enum SecutgTwoStepNav {
    static func open(context: AccountContext, controller: ViewController) {
        let _ = (context.engine.auth.twoStepVerificationConfiguration()
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak controller] config in
            guard let controller else { return }
            switch config {
            case .notSet:
                controller.push(context.sharedContext.makeSetupTwoFactorAuthController(context: context))
            case .set:
                controller.push(context.sharedContext.makePrivacyAndSecurityController(context: context))
            }
        })
    }
}
