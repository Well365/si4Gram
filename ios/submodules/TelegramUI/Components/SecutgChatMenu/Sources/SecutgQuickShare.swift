import Foundation
import UIKit
import AsyncDisplayKit
import Display
import Postbox
import TelegramCore
import AccountContext
import QrCodeUI
import UIKitRuntimeUtils
import SecutgCore

/// SECUTG: PLAN.md 3.14.1 — one chat's keys (Saved Messages or an encrypted group) to another device of this same
/// user by one QR code, `K1Q:<code>:<K1 container>`. The export side shows the code full-screen under the warning;
/// the import side reuses the app's QR scanner and then the ordinary 3.14 import (manifest first, confirm, merge,
/// never rolling a group's newer binding back — Saved Messages alone is taken over, see `KeyRing.mergeQuickShare`).
/// No new crypto: the container is the 3.14 one, the code simply rides along.
extension SecutgTransfer {
    // MARK: export

    public static func presentQuickShare(context: AccountContext, controller: ViewController, peerId: PeerId) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        SecutgChatMenu.syncLanguage(context: context)
        // PLAN.md 3.39.13: a 1v1 chat's binding belongs to a device identity, so its QR is the V2Q clone (that identity
        // and the chat's keys), never a K1 slice — `SecutgV2Join` owns that page.
        if peerId.namespace == Namespaces.Peer.CloudUser, peerId != context.account.peerId {
            SecutgV2Join.presentShare(context: context, controller: controller, peerId: peerId)
            return
        }
        let outcome: QuickShare.Outcome
        do {
            outcome = try runtime.exportQuickShare(chatPeerId: peerId)
        } catch SecutgAccountRuntime.TransferError.nothingToExport {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgQuickShareNoKey"))
            return
        } catch {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgOperationFailed", ["error": "\(error)"]))
            return
        }
        switch outcome {
        case .noKey:
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgQuickShareNoKey"))
        case .tooLarge:
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgQuickShareTooLarge"))
        case let .full(text, _):
            presentCodePage(context: context, controller: controller, peerId: peerId, text: text, kind: .k1q, partialNote: nil)
        case let .partial(text, masterCount, _):
            let note = SecutgL10n.string("SecutgQuickSharePartial", ["n": "\(masterCount)"])
            presentCodePage(context: context, controller: controller, peerId: peerId, text: text, kind: .k1q, partialNote: note)
        }
    }

    // MARK: import

    /// The app's own QR scanner; the first code it reads decides, and the scanner closes itself.
    /// `peerId` is the chat the scan was started from: a `V2Q:` frame (PLAN.md 3.39) is an import INTO that very chat
    /// and only makes sense in a 1v1 one; a `K1Q:` frame names its own chat and is imported wherever it was scanned.
    public static func presentQuickShareScan(context: AccountContext, controller: ViewController, peerId: PeerId? = nil) {
        guard SecutgHookRegistry.shared.runtime(for: context.account.peerId) != nil else { return }
        SecutgChatMenu.syncLanguage(context: context)
        // PLAN.md 3.39.14: no camera (or no permission to use it) — say how the code gets here as a file instead.
        guard cameraUsable() else {
            presentNoCamera(context: context, controller: controller, peerId: peerId)
            return
        }
        let scanner = QrCodeScanScreen(context: context, subject: .custom(info: SecutgL10n.string("SecutgQuickShareScan")))
        var handled = false
        scanner.completion = { [weak controller, weak scanner] code in
            guard !handled, let code else { return }
            handled = true
            scanner?.dismissAnimated()
            guard let controller else { return }
            importCodeText(context: context, controller: controller, peerId: peerId, text: code, file: nil)
        }
        controller.push(scanner)
    }

    /// A `K1Q:` text from the scanner (or pasted into the keyring import dialog): split it, check it opens as a
    /// chat-scope container, then the ordinary 3.14 manifest → confirm → merge. `SecutgQuickShareBadQr` for all three
    /// refusals (malformed / undecryptable / whole-keyring file).
    /// `file`: PLAN.md 3.39.14 — the code came from this file (refusals then name the file, success offers to delete it).
    static func importQuickShare(context: AccountContext, controller: ViewController, text: String, file: SecutgImportedFile? = nil) {
        switch QuickShare.open(text) {
        case let .success(opened):
            presentSummary(context: context, controller: controller, bundle: opened.parsed.bundle, code: opened.parsed.code, quickShare: true, file: file)
        case .failure:
            SecutgChatMenu.toast(controller, SecutgL10n.string(file == nil ? "SecutgQuickShareBadQr" : "SecutgShareFileBad"))
        }
    }
}

/// Full-screen QR of a `K1Q:` text under the PLAN.md 3.14.1 warning. Deliberately no copy button: the text is the
/// key, and the one way it is meant to leave this screen is a camera of the user's own other device. The whole
/// screen is kept out of screenshots and screen recordings with the same layer trick Telegram uses for secret chats.
public final class SecutgQuickShareQrController: ViewController {
    private let text: String
    private let partialNote: String?
    /// PLAN.md 3.39.3 / 3.39.13: the V2Q page's own subtitle (`SecutgV2JoinQrHint` + `SecutgV2CloneWarn`), under the
    /// shared warning; nil for a K1Q.
    private let hint: String?
    private let titleLabel = UILabel()
    private let warningLabel = UILabel()
    private let hintLabel = UILabel()
    private let partialLabel = UILabel()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)
    private let scroll = UIScrollView()
    /// PLAN.md 3.39.12 item 4: the capacity rule's error-correction level ("L" for a V2Q past 2331 bytes).
    private let correctionLevel: String
    /// PLAN.md 3.39.14: 〔用文件分享〕 and its warning; nil on a page that offers no file (the A1Q credentials code).
    private let codeFile: SecutgTransfer.CodeFile?
    private let fileWarningLabel = UILabel()
    private let shareFileButton = UIButton(type: .system)

    /// PLAN.md 3.40.4: the same protected page shows the `A1Q:` API-credentials code, with its own title and warning.
    private let heading: String?
    private let warning: String?

    public init(text: String, partialNote: String?, hint: String? = nil, title: String? = nil, warning: String? = nil,
                correctionLevel: String = "M", codeFile: SecutgTransfer.CodeFile? = nil) {
        self.correctionLevel = correctionLevel
        self.codeFile = codeFile
        self.text = text
        self.partialNote = partialNote
        self.hint = hint
        self.heading = title
        self.warning = warning
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = .white
        self.displayNodeDidLoad()
        self.displayNode.view.addSubview(scroll)
        setLayerDisableScreenshots(self.displayNode.layer, true)

        titleLabel.text = heading ?? SecutgL10n.string("SecutgQuickShare")
        titleLabel.font = UIFont.boldSystemFont(ofSize: 20.0)
        titleLabel.textColor = .black
        titleLabel.textAlignment = .center
        warningLabel.text = warning ?? SecutgL10n.string("SecutgQuickShareWarn")
        warningLabel.font = UIFont.boldSystemFont(ofSize: 16.0)
        warningLabel.textColor = UIColor(red: 0.8, green: 0.15, blue: 0.15, alpha: 1.0)
        warningLabel.textAlignment = .center
        hintLabel.text = hint
        hintLabel.font = UIFont.systemFont(ofSize: 15.0)
        hintLabel.textColor = .darkGray
        hintLabel.textAlignment = .center
        hintLabel.isHidden = hint == nil
        partialLabel.text = partialNote
        partialLabel.font = UIFont.systemFont(ofSize: 14.0)
        partialLabel.textColor = UIColor(red: 0.6, green: 0.4, blue: 0.0, alpha: 1.0)
        partialLabel.textAlignment = .center
        partialLabel.isHidden = partialNote == nil
        for label in [titleLabel, warningLabel, hintLabel, partialLabel] {
            label.numberOfLines = 0
            scroll.addSubview(label)
        }
        imageView.contentMode = .scaleAspectFit
        imageView.layer.magnificationFilter = .nearest
        imageView.image = SecutgKeyQrController.render(text, correctionLevel: correctionLevel)
        scroll.addSubview(imageView)
        if let codeFile {
            fileWarningLabel.text = codeFile.warning
            fileWarningLabel.font = UIFont.systemFont(ofSize: 14.0)
            fileWarningLabel.textColor = UIColor(red: 0.8, green: 0.15, blue: 0.15, alpha: 1.0)
            fileWarningLabel.textAlignment = .center
            fileWarningLabel.numberOfLines = 0
            scroll.addSubview(fileWarningLabel)
            shareFileButton.setTitle(SecutgL10n.string("SecutgShareFile"), for: .normal)
            shareFileButton.addTarget(self, action: #selector(shareFileTapped), for: .touchUpInside)
            scroll.addSubview(shareFileButton)
        }
        closeButton.setTitle(SecutgL10n.string("SecutgClose"), for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        scroll.addSubview(closeButton)
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let inset: CGFloat = 20.0
        let width = layout.size.width - inset * 2.0
        scroll.frame = CGRect(origin: CGPoint(), size: layout.size)
        var y = layout.safeInsets.top + 24.0
        func place(_ view: UIView, height: CGFloat? = nil, gap: CGFloat = 12.0) {
            let fitted = height ?? view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            view.frame = CGRect(x: inset, y: y, width: width, height: fitted)
            y += fitted + gap
        }
        place(titleLabel)
        place(warningLabel, gap: hintLabel.isHidden ? 16.0 : 8.0)
        if !hintLabel.isHidden {
            place(hintLabel, gap: 16.0)
        }
        // A dense code (up to version 40) needs every point the screen has, so it takes the full width.
        let side = min(width, 420.0)
        imageView.frame = CGRect(x: (layout.size.width - side) / 2.0, y: y, width: side, height: side)
        y += side + 16.0
        if !partialLabel.isHidden {
            place(partialLabel, gap: 16.0)
        }
        if codeFile != nil {
            place(shareFileButton, height: 44.0, gap: 4.0)
            place(fileWarningLabel, gap: 16.0)
        }
        place(closeButton, height: 44.0)
        scroll.contentSize = CGSize(width: layout.size.width, height: y + layout.intrinsicInsets.bottom + 24.0)
    }

    @objc private func closeTapped() {
        self.dismiss()
    }

    /// PLAN.md 3.39.14: the same text as the QR, as `secuTG-分享码-<chat>-<time>.secutg-v2q|k1q`, through the system share
    /// sheet (AirDrop, Save to Files, …). Copying to the clipboard is excluded: the page never offers the text itself.
    /// The temporary copy is removed when the sheet closes.
    @objc private func shareFileTapped() {
        guard let codeFile else { return }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("secutg-share", isDirectory: true)
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04): "Si4Gram-" + the localized share-code noun, not the
            // hardcoded Chinese `ShareCodeFile.namePrefix`; the importer keys on content + extension, so old
            // "secuTG-分享码-…" files still import unchanged.
            let name = ShareCodeFile.fileName(kind: codeFile.kind, chatName: codeFile.chatName, fallback: codeFile.fallback, date: Date(), namePrefix: "Si4Gram-" + SecutgL10n.string("SecutgShareFileNamePart"))
            let url = directory.appendingPathComponent(name)
            try ShareCodeFile.contents(text).write(to: url, options: [.atomic, .completeFileProtection])
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.excludedActivityTypes = [.copyToPasteboard]
            activity.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: url)
            }
            if let popover = activity.popoverPresentationController {
                popover.sourceView = shareFileButton
                popover.sourceRect = shareFileButton.bounds
            }
            SecutgTransfer.presentSystem(activity, over: self)
        } catch {
            shareFileButton.setTitle(SecutgL10n.string("SecutgOperationFailed", ["error": "\(error)"]), for: .normal)
        }
    }
}
