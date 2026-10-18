import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// SECUTG: PLAN.md 3.39.13 — a 1v1 chat CLONED onto another device of this same user by one QR code,
/// `V2Q:<code>:<nonce>:<ct>`: the scanning device becomes the showing device in that chat (same identity, same keys).
/// The showing side (O) reuses the 3.14.1 QR page (`SecutgQuickShareQrController`) under the same warning, with 3.39's
/// hint and 3.39.13's `SecutgV2CloneWarn`; the scanning side (N) reuses the app's QR scanner
/// (`SecutgTransfer.presentQuickShareScan`, which hands a `V2Q:` frame here), shows the manifest with the same warning,
/// and installs on confirmation. Nothing is sent and nothing waits. Everything that decides is `SecutgAccountRuntime` /
/// `V2JoinCoordinator`; this file only asks and shows.
public enum SecutgV2Join {
    // MARK: showing side (O)

    /// 〔扫码分享到我的设备〕 in a 1v1 chat's 「密钥搬运」 list. Refusals are one toast each; the code page carries
    /// `SecutgQuickShareWarn`, `SecutgV2JoinQrHint` + `SecutgV2CloneWarn`, and `SecutgQuickSharePartial {n}` when history
    /// was dropped.
    public static func presentShare(context: AccountContext, controller: ViewController, peerId: PeerId) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        SecutgChatMenu.syncLanguage(context: context)
        switch runtime.prepareJoinShare(chatPeerId: peerId) {
        case .notOnV2, .notPaired:
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgV2JoinNotPaired"))
        case .tooLarge:
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgQuickShareTooLarge"))
        case let .failed(reason):
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgOperationFailed", ["error": reason]))
        case let .shown(share):
            // PLAN.md 3.46.1 step 3: remember that this chat's code was shown here — chat id and time only.
            SecutgLocalPrefs.noteLostDeviceShownCode(accountKey: SecutgLocalPrefs.accountKey(context.account.peerId), chatId: SecutgAccountRuntime.chatKey(peerId))
            let partial = share.historyDropped > 0 ? SecutgL10n.string("SecutgQuickSharePartial", ["n": "\(share.keyCount)"]) : nil
            let hint = SecutgChatMenu.joined(SecutgL10n.string("SecutgV2JoinQrHint"), SecutgL10n.string("SecutgV2CloneWarn"))
            // SECUTG-HOOK (fix, 2026-10-02): the capacity rule's own level — a code past 2331 bytes is L, and an M
            // request for it rendered nothing. PLAN.md 3.39.14: the page also offers the code as a file.
            SecutgTransfer.presentCodePage(context: context, controller: controller, peerId: peerId, text: share.text, kind: .v2q,
                                           partialNote: partial, hint: hint, correctionLevel: share.ecc.rawValue)
        }
    }

    // MARK: scanning side (N)

    /// A `V2Q:` frame from the scanner, read in `peerId`'s chat (the code must name this very chat).
    /// Manifest (with `SecutgV2CloneWarn`) → confirm → install → the chat is readable and sendable at once.
    /// `file`: PLAN.md 3.39.14 — the code was read from this file; success then offers 〔删除这个文件〕.
    public static func importScanned(context: AccountContext, controller: ViewController, peerId: PeerId, text: String) {
        importScanned(context: context, controller: controller, peerId: peerId, text: text, file: nil)
    }

    static func importScanned(context: AccountContext, controller: ViewController, peerId: PeerId, text: String, file: SecutgImportedFile?) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        SecutgChatMenu.syncLanguage(context: context)
        switch runtime.inspectJoin(chatPeerId: peerId, text: text) {
        case .notOnV2:
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgQuickShareBadQr"))
        case let .refused(refusal):
            SecutgChatMenu.toast(controller, refusalText(refusal, file: file))
        case let .ok(manifest):
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)) |> deliverOnMainQueue).start(next: { [weak controller] peer in
                guard let controller else { return }
                let presentation = context.sharedContext.currentPresentationData.with { $0 }
                let name = peer?.displayTitle(strings: presentation.strings, displayOrder: presentation.nameDisplayOrder) ?? manifest.peerUserId
                var lines = [SecutgL10n.string("SecutgV2JoinManifest", ["name": name, "code": manifest.safetyCode])]
                // the same shape 3.14's manifest uses: how many keys ride along
                lines.append(SecutgL10n.string("SecutgExportSummary", ["scope": SecutgL10n.string("SecutgScopeChat"), "chats": "1", "masters": "\(manifest.historyCount + 1)"]))
                // PLAN.md 3.39.13: the import confirmation says what the clone costs, before anything is written.
                lines.append(SecutgL10n.string("SecutgV2CloneWarn"))
                let sheet = UIAlertController(title: SecutgL10n.string("SecutgQuickShareScan"), message: lines.joined(separator: "\n\n"), preferredStyle: .alert)
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportConfirm"), style: .default, handler: { [weak controller] _ in
                    guard let controller else { return }
                    install(context: context, controller: controller, peerId: peerId, text: text, runtime: runtime, file: file)
                }))
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
                SecutgChatMenu.presentSystem(sheet, over: controller)
            })
        }
    }

    /// Installs the clone; the chat's sealed history is swept (the masters just arrived) and the user is told the chat
    /// is ready, with the safety code to compare (`SecutgV2JoinDone`).
    private static func install(context: AccountContext, controller: ViewController, peerId: PeerId, text: String, runtime: SecutgAccountRuntime, file: SecutgImportedFile?) {
        switch runtime.installJoin(chatPeerId: peerId, text: text) {
        case .notOnV2:
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgQuickShareBadQr"))
        case let .refused(refusal):
            SecutgChatMenu.toast(controller, refusalText(refusal, file: file))
        case .installed:
            let done = SecutgL10n.string("SecutgV2JoinDone", ["code": runtime.safetyCode(chatPeerId: peerId) ?? ""])
            // PLAN.md 3.17: a key arrived — the messages already stored under it can be opened now.
            SecutgChatMenu.redecrypt(context: context, peerIds: [peerId], completion: { [weak controller] line in
                guard let controller else { return }
                if let file {
                    file.presentDone(title: SecutgL10n.string("SecutgQuickShareScan"), message: SecutgChatMenu.joined(done, line), over: controller)
                    return
                }
                let sheet = UIAlertController(title: SecutgL10n.string("SecutgQuickShareScan"), message: SecutgChatMenu.joined(done, line), preferredStyle: .alert)
                sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .cancel))
                SecutgChatMenu.presentSystem(sheet, over: controller)
            })
        }
    }

    private static func refusalText(_ refusal: V2JoinCoordinator.ImportRefusal, file: SecutgImportedFile?) -> String {
        switch refusal {
        case .alreadyPaired: return SecutgL10n.string("SecutgV2JoinAlreadyPaired")
        case .wrongChat: return SecutgL10n.string("SecutgV2JoinWrongChat")
        case .expired: return SecutgL10n.string("SecutgV2JoinExpired")
        case .oldVersion: return SecutgL10n.string("SecutgV2CloneOldVersion")
        case .malformed, .undecryptable: return SecutgL10n.string(file == nil ? "SecutgQuickShareBadQr" : "SecutgShareFileBad")
        }
    }
}
