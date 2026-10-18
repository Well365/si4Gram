import Foundation
import UIKit
import AVFoundation
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// SECUTG: PLAN.md 3.39.14 — the V2Q / K1Q code as a file, for a device that cannot point a camera at the code page
/// (which blocks screenshots and has no copy button). The share side writes exactly the QR's text into
/// `secuTG-分享码-<chat>-<time>.secutg-v2q|k1q` and hands it to the system share sheet; the import side reads such a
/// file and feeds its text into the very same import as a scanned code (same manifest, same refusals). After a
/// successful import the user is offered 〔删除这个文件〕, and only that tap deletes it. Rules live in `ShareCodeFile`.
extension SecutgTransfer {
    /// What a code page needs to offer its file: the name parts (the time is taken when the file is written).
    public struct CodeFile {
        let kind: ShareCodeFile.Kind
        let chatName: String
        let fallback: String

        var warning: String {
            let warn = SecutgL10n.string("SecutgShareFileWarn")
            return kind == .v2q ? warn + "\n" + SecutgL10n.string("SecutgShareFileExpiry") : warn
        }
    }

    /// The code page for `peerId`, once the chat's name is known (it goes into the file name).
    static func presentCodePage(context: AccountContext, controller: ViewController, peerId: PeerId, text: String, kind: ShareCodeFile.Kind,
                                partialNote: String?, hint: String? = nil, correctionLevel: String = "M") {
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)) |> deliverOnMainQueue).start(next: { [weak controller] peer in
            guard let controller else { return }
            let presentation = context.sharedContext.currentPresentationData.with { $0 }
            let name = peer?.displayTitle(strings: presentation.strings, displayOrder: presentation.nameDisplayOrder) ?? ""
            let file = CodeFile(kind: kind, chatName: name, fallback: SecutgAccountRuntime.chatKey(peerId))
            controller.present(SecutgQuickShareQrController(text: text, partialNote: partialNote, hint: hint, correctionLevel: correctionLevel, codeFile: file),
                               in: .window(.root))
        })
    }

    // MARK: import

    /// The camera is there and may be used; `.notDetermined` counts as usable — the scanner asks.
    static func cameraUsable() -> Bool {
        guard AVCaptureDevice.default(for: .video) != nil else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: return false
        default: return true
        }
    }

    /// PLAN.md 3.39.14: the scan entry on a device without a usable camera says where to go instead.
    static func presentNoCamera(context: AccountContext, controller: ViewController, peerId: PeerId?) {
        let sheet = UIAlertController(title: SecutgL10n.string("SecutgQuickShareScan"), message: SecutgL10n.string("SecutgNoCameraUseFile"), preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportFromFile"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            presentCodeFileImport(context: context, controller: controller, peerId: peerId)
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(sheet, over: controller)
    }

    private static var codeFilePickerDelegate: CodeFilePickerDelegate?

    /// 〔从文件导入〕: the document picker in open mode (the file stays where it is, so it can be deleted afterwards).
    public static func presentCodeFileImport(context: AccountContext, controller: ViewController, peerId: PeerId?) {
        guard SecutgHookRegistry.shared.runtime(for: context.account.peerId) != nil else { return }
        SecutgChatMenu.syncLanguage(context: context)
        let picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .open)
        let delegate = CodeFilePickerDelegate { [weak controller] url, text in
            codeFilePickerDelegate = nil
            guard let controller, let url else { return }
            guard let text, ShareCodeFile.kind(of: text) != nil else {
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgShareFileBad"))
                return
            }
            importCodeText(context: context, controller: controller, peerId: peerId, text: text, file: SecutgImportedFile(url: url))
        }
        codeFilePickerDelegate = delegate
        picker.delegate = delegate
        if let popover = picker.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1.0, height: 1.0)
        }
        presentSystem(picker, over: controller)
    }

    /// One road for a scanned code and a code read from a file: a `V2Q:` is an import INTO `peerId`'s 1v1 chat, a
    /// `K1Q:` names its own chat. `file` is the file it came from, offered for deletion after a successful import.
    static func importCodeText(context: AccountContext, controller: ViewController, peerId: PeerId?, text: String, file: SecutgImportedFile?) {
        if V2JoinText.isV2JoinText(text) {
            guard let peerId, peerId.namespace == Namespaces.Peer.CloudUser, peerId != context.account.peerId else {
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgV2JoinWrongChat"))
                return
            }
            SecutgV2Join.importScanned(context: context, controller: controller, peerId: peerId, text: text, file: file)
            return
        }
        importQuickShare(context: context, controller: controller, text: text, file: file)
    }

    /// Runs `action` once `picker` is off screen (≤ 2 s): an alert presented on a view controller that is being
    /// dismissed is silently dropped by UIKit — the same bug class as the 1b46a7e8 scanner fix.
    static func afterDismissal(of picker: UIViewController, attempts: Int = 20, _ action: @escaping () -> Void) {
        if picker.presentingViewController == nil || attempts <= 0 {
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            afterDismissal(of: picker, attempts: attempts - 1, action)
        }
    }
}

/// A code file the user picked: after a successful import the done message carries 〔删除这个文件〕, and the file is
/// deleted (moved to the trash where the location has one) only when that is tapped.
final class SecutgImportedFile {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func presentDone(title: String, message: String, over controller: ViewController) {
        let sheet = UIAlertController(title: title, message: message, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgDeleteThisFile"), style: .destructive, handler: { [weak controller] _ in
            guard let controller else { return }
            let deleted = self.delete()
            SecutgChatMenu.toast(controller, SecutgL10n.string(deleted ? "SecutgShareFileDeleted" : "SecutgShareFileDeleteFailed"))
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .cancel))
        SecutgChatMenu.presentSystem(sheet, over: controller)
    }

    private func delete() -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            do {
                try FileManager.default.removeItem(at: url)
                return true
            } catch {
                return false
            }
        }
    }
}

/// Reads at most `ShareCodeFile.maxFileBytes` (+1, so an oversized file is recognised) of the picked file inside its
/// security scope, then hands URL and text back once the picker is gone.
private final class CodeFilePickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: (URL?, String?) -> Void

    init(completion: @escaping (URL?, String?) -> Void) {
        self.completion = completion
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion(nil, nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            completion(nil, nil)
            return
        }
        let text = CodeFilePickerDelegate.read(url)
        let completion = self.completion
        SecutgTransfer.afterDismissal(of: controller) {
            completion(url, text)
        }
    }

    private static func read(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }
        return ShareCodeFile.readText(handle.readData(ofLength: ShareCodeFile.maxFileBytes + 1))
    }
}
