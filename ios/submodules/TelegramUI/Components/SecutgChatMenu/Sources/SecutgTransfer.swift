import Foundation
import UIKit
import AsyncDisplayKit
import Display
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// SECUTG: keyring transfer between this user's own devices (PLAN.md 3.14). Export builds a `K1` file under a
/// one-time transfer code and offers it through the system share sheet (AirDrop) or the clipboard; import takes the
/// file back through the document picker or a paste, shows what is inside and only then merges it into the keyring.
/// Every string goes through `SecutgL10n`, so the flow follows the Telegram language.
public enum SecutgTransfer {
    // MARK: export

    public static func presentExport(context: AccountContext, controller: ViewController, scope: TransferScope, chatPeerIds: [PeerId] = [], withIdentity: Bool = false) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        SecutgChatMenu.syncLanguage(context: context)
        // PLAN.md 3.25.4 rule 2: "不包含设备备注" defaults unchecked (= labels included); the export screen's
        // own switch re-runs this closure so toggling it regenerates the file (and its one-time code) in place.
        let build: (Bool) -> SecutgAccountRuntime.ExportResult? = { includeDeviceLabels in
            try? runtime.exportKeyring(scope: scope, chatPeerIds: chatPeerIds, withIdentity: withIdentity, includeDeviceLabels: includeDeviceLabels)
        }
        guard let result = build(true) else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgOperationFailed", ["error": "export"]))
            return
        }
        // PLAN.md 3.46 check 7: a whole-keyring export is this device's backup; its time is what the check-up compares
        // with the newest key. Recorded only when the file actually leaves the screen (shared or its text copied) —
        // opening the window and closing it again is not a backup (as Web's download and Android's share/save/copy).
        let accountKey = SecutgLocalPrefs.accountKey(context.account.peerId)
        let onHandOff: (() -> Void)? = scope == .all ? { SecutgLocalPrefs.noteAuditBackup(accountKey: accountKey) } : nil
        controller.present(SecutgTransferExportController(result: result, rebuild: build, onHandOff: onHandOff), in: .window(.root))
    }

    // MARK: import

    /// Step 1: where does the file come from — the document picker, or a paste of the `K1:…` text.
    ///
    /// `peerId` is the chat this dialog was opened from, and nil when it was opened from the secuTG settings
    /// screen, which belongs to no chat. It exists for one reason: an offline key pasted in here can only be
    /// offered a way out **when there is a chat to send the user to** — see `promptBundleText`.
    public static func presentImport(context: AccountContext, controller: ViewController, peerId: PeerId? = nil) {
        guard SecutgHookRegistry.shared.runtime(for: context.account.peerId) != nil else { return }
        SecutgChatMenu.syncLanguage(context: context)
        let sheet = UIAlertController(title: SecutgL10n.string("SecutgImportKeyringTitle"), message: SecutgL10n.string("SecutgTransferDesc"), preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportPickFile"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            pickFile(context: context, controller: controller)
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportPasteBundle"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            promptBundleText(context: context, controller: controller, peerId: peerId)
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(sheet, over: controller)
    }

    private static var pickerDelegate: FilePickerDelegate?

    private static func pickFile(context: AccountContext, controller: ViewController) {
        let picker = UIDocumentPickerViewController(documentTypes: ["public.data", "public.text"], in: .import)
        let delegate = FilePickerDelegate { [weak controller] text in
            pickerDelegate = nil
            guard let controller, let text, TransferBundle.isTransferBundle(text) else {
                if let controller { SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgImportBadCode")) }
                return
            }
            promptCode(context: context, controller: controller, bundle: text)
        }
        pickerDelegate = delegate
        picker.delegate = delegate
        if let popover = picker.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1.0, height: 1.0)
        }
        presentSystem(picker, over: controller)
    }

    private static func promptBundleText(context: AccountContext, controller: ViewController, peerId: PeerId?) {
        let input = UIAlertController(title: SecutgL10n.string("SecutgImportKeyringTitle"), message: SecutgL10n.string("SecutgImportPasteBundle"), preferredStyle: .alert)
        input.addTextField { field in
            field.placeholder = "K1:1:…"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            if let pasted = UIPasteboard.general.string, TransferBundle.isTransferBundle(pasted) { field.text = pasted }
        }
        input.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportInspect"), style: .default, handler: { [weak input, weak controller] _ in
            guard let controller else { return }
            let text = (input?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // PLAN.md 3.14.1: a quick-share QR's text carries its own code, so it skips the code step.
            if QuickShare.isQuickShare(text) {
                importQuickShare(context: context, controller: controller, text: text)
                return
            }
            guard TransferBundle.isTransferBundle(text) else {
                // The mirror of the guidance in the offline key dialog: an offline key pasted here is
                // just as likely a mistake, and "the transfer code does not match this file" is just
                // as unhelpful an answer to it.
                //
                // Whether it can also *offer the way out* depends on where this dialog was opened from,
                // and that asymmetry is the point rather than an omission. An offline key is bound to one
                // chat — importing it writes a master for that chatId, and a group member then announces
                // their public key into that same chat — so "open the offline key dialog" has a
                // destination only when a chat is already in hand. Opened from the chat's own transfer
                // menu there is one, and the paste is carried across so nobody hunts for it twice; opened
                // from the secuTG settings screen (PLAN.md 3.29.1) there is none, and the dialog names
                // what the text is and stops there. Android and macOS split it the same way.
                if ImportText.classify(text) == .keyPayload {
                    let jump: (String, () -> Void)? = peerId.map { peerId in
                        (SecutgL10n.string("SecutgImportWrongDialogOpenKey"), { [weak controller] in
                            guard let controller else { return }
                            SecutgChatMenu.presentOfflineKeyImport(
                                context: context, peerId: peerId, controller: controller, prefill: text)
                        })
                    }
                    SecutgChatMenu.presentWrongImportDialog(
                        controller: controller,
                        title: SecutgL10n.string("SecutgImportTitle"),
                        message: SecutgL10n.string("SecutgImportWrongDialogKeyPayload"),
                        action: jump)
                } else {
                    SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgImportBadCode"))
                }
                return
            }
            promptCode(context: context, controller: controller, bundle: text)
        }))
        input.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(input, over: controller)
    }

    /// The text is already in hand — the user pasted a `K1:` file into the offline key dialog and took
    /// the offer to come here — so step 1 has nothing left to ask and this goes straight to the code.
    public static func presentImport(context: AccountContext, controller: ViewController, pastedBundle: String) {
        guard SecutgHookRegistry.shared.runtime(for: context.account.peerId) != nil else { return }
        SecutgChatMenu.syncLanguage(context: context)
        promptCode(context: context, controller: controller, bundle: pastedBundle)
    }

    /// Step 2: the transfer code the other device showed once.
    private static func promptCode(context: AccountContext, controller: ViewController, bundle: String) {
        let input = UIAlertController(title: SecutgL10n.string("SecutgImportKeyringTitle"), message: SecutgL10n.string("SecutgImportCodeLabel"), preferredStyle: .alert)
        input.addTextField { field in
            field.placeholder = "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
            field.font = UIFont.monospacedDigitSystemFont(ofSize: 15.0, weight: .regular)
        }
        input.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportInspect"), style: .default, handler: { [weak input, weak controller] _ in
            guard let controller else { return }
            presentSummary(context: context, controller: controller, bundle: bundle, code: input?.textFields?.first?.text ?? "")
        }))
        input.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(input, over: controller)
    }

    /// Step 3: nothing is written yet — show scope, chat and key counts, source device, export date, whether the
    /// identity key is in there and the "older than a week" warning, and only merge after the user confirms.
    /// Internal rather than private since PLAN.md 3.14.1: the quick-share QR import (`SecutgQuickShare.swift`) lands here too.
    /// `quickShare`: the text came from a 3.14.1 QR, so the merge is `importQuickShare` (Saved Messages takeover).
    static func presentSummary(context: AccountContext, controller: ViewController, bundle: String, code: String, quickShare: Bool = false,
                               file: SecutgImportedFile? = nil) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let inspected: SecutgAccountRuntime.InspectResult
        do {
            inspected = try runtime.inspectKeyring(bundle: bundle, code: code)
        } catch {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgImportBadCode"))
            return
        }
        let summary = inspected.summary
        var lines = [
            SecutgL10n.string("SecutgExportSummary", [
                "scope": SecutgL10n.string(summary.scope == .all ? "SecutgScopeAll" : "SecutgScopeChat"),
                "chats": "\(summary.chatCount)",
                "masters": "\(summary.masterCount)",
            ]),
            SecutgL10n.string("SecutgImportFromDevice", ["device": summary.device, "date": dateText(summary.createdAt)]),
            SecutgL10n.string(summary.hasIdentity ? "SecutgImportWithIdentity" : "SecutgImportWithoutIdentity"),
            // PLAN.md 3.14 import step 1 / 3.25.4 rule 2
            SecutgL10n.string(summary.hasDeviceLabels ? "SecutgImportWithDeviceLabels" : "SecutgImportWithoutDeviceLabels"),
        ]
        // PLAN.md 3.30 item 8: said on the way in as well — this is the power this device is about to take on,
        // not merely the chats it is about to be able to read. Only when the file actually carries one.
        if summary.adminChatCount > 0 {
            lines.append(SecutgL10n.string("SecutgImportWithAdminKeys", ["count": "\(summary.adminChatCount)"]))
        }
        if summary.isStale { lines.append(SecutgL10n.string("SecutgImportStale")) }

        let sheet = UIAlertController(title: SecutgL10n.string("SecutgImportKeyringTitle"), message: lines.joined(separator: "\n"), preferredStyle: .alert)
        // PLAN.md 3.39.7: a single chat's import (a chat-scope K1 file, a K1Q, a V2Q) never touches this device's
        // global identity; the runtime already answers `needsIdentityChoice` false for those, and this is the backstop.
        if inspected.needsIdentityChoice && summary.scope == .all {
            // PLAN.md 3.14 rule 3: the two ways out when this device already has a different identity
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportReplaceIdentity"), style: .destructive, handler: { [weak controller] _ in
                guard let controller else { return }
                confirmIdentityReplacement(context: context, controller: controller, bundle: bundle, code: code, quickShare: quickShare, file: file)
            }))
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportKeepIdentity"), style: .default, handler: { [weak controller] _ in
                guard let controller else { return }
                apply(context: context, controller: controller, bundle: bundle, code: code, replaceIdentity: false, quickShare: quickShare, file: file)
            }))
        } else {
            sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportConfirm"), style: .default, handler: { [weak controller] _ in
                guard let controller else { return }
                apply(context: context, controller: controller, bundle: bundle, code: code, replaceIdentity: false, quickShare: quickShare, file: file)
            }))
        }
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(sheet, over: controller)
    }

    private static func confirmIdentityReplacement(context: AccountContext, controller: ViewController, bundle: String, code: String, quickShare: Bool, file: SecutgImportedFile?) {
        let sheet = UIAlertController(title: SecutgL10n.string("SecutgImportIdentityTitle"), message: SecutgL10n.string("SecutgImportIdentityBody"), preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportReplaceIdentity"), style: .destructive, handler: { [weak controller] _ in
            guard let controller else { return }
            apply(context: context, controller: controller, bundle: bundle, code: code, replaceIdentity: true, quickShare: quickShare, file: file)
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgImportKeepIdentity"), style: .default, handler: { [weak controller] _ in
            guard let controller else { return }
            apply(context: context, controller: controller, bundle: bundle, code: code, replaceIdentity: false, quickShare: quickShare, file: file)
        }))
        sheet.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(sheet, over: controller)
    }

    private static func apply(context: AccountContext, controller: ViewController, bundle: String, code: String, replaceIdentity: Bool, quickShare: Bool, file: SecutgImportedFile?) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        do {
            // PLAN.md 3.14.1: a quick share never carries an identity, so `replaceIdentity` has nothing to act on there
            let result: KeyRingMergeResult
            if quickShare {
                result = try runtime.importQuickShare(bundle: bundle, code: code)
            } else {
                result = try runtime.importKeyring(bundle: bundle, code: code, replaceIdentity: replaceIdentity)
            }
            var text = SecutgL10n.string("SecutgImportDone", ["masters": "\(result.addedMasters)", "chats": "\(result.boundChats.count)"])
            if !result.skippedChats.isEmpty {
                text += "\n" + SecutgL10n.string("SecutgImportSkipped", ["count": "\(result.skippedChats.count)"])
            }
            // PLAN.md 3.17: a transferred keyring can open messages in any chat, so this one sweeps them all
            SecutgChatMenu.redecrypt(context: context, peerIds: nil, completion: { [weak controller] line in
                guard let controller else { return }
                // PLAN.md 3.39.14: an import from a code file offers to delete that file — only on the tap.
                if let file {
                    file.presentDone(title: "Si4Gram", message: SecutgChatMenu.joined(text, line), over: controller) // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
                    return
                }
                SecutgChatMenu.toast(controller, SecutgChatMenu.joined(text, line))
            })
        } catch {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgImportBadCode"))
        }
    }

    // MARK: helpers

    static func dateText(_ unixSeconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    static func presentSystem(_ viewController: UIViewController, over controller: ViewController) {
        // SECUTG-HOOK (fix, 2026-10-02, PLAN.md 3.37.1): pickers / share sheets wait for the passcode lock too.
        SecutgAppLock.presentModal(viewController, from: { [weak controller] in controller?.view.window?.rootViewController })
    }
}

/// Reads the picked `.secutg` file and hands its text back; retained by `SecutgTransfer` while the picker is up.
private final class FilePickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: (String?) -> Void

    init(completion: @escaping (String?) -> Void) {
        self.completion = completion
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion(nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { completion(nil); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = try? String(contentsOf: url, encoding: .utf8)
        // SECUTG-HOOK (fix, 2026-10-02): an alert presented while the picker is still on its way out is dropped.
        let completion = self.completion
        SecutgTransfer.afterDismissal(of: controller) {
            completion(text?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// The export sheet: what is inside, the one-time transfer code as a monospace block with a copy button, the
/// "shown once" hint, the warning from PLAN.md 3.14, then "Share…" (a real `.secutg` file through the system share
/// sheet, so AirDrop works) and a copy of the `K1:` text itself.
public final class SecutgTransferExportController: ViewController {
    private var result: SecutgAccountRuntime.ExportResult
    /// PLAN.md 3.25.4 rule 2: re-runs the export with the switch's current state; nil on failure (leaves the
    /// screen showing the last successful export rather than a blank one).
    private let rebuild: (Bool) -> SecutgAccountRuntime.ExportResult?
    private var includeDeviceLabels = true
    private let scroll = UIScrollView()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    /// PLAN.md 3.30 item 8. Its own label rather than another line inside `summaryLabel` because it is not part
    /// of the same sentence: the summary counts what this file lets the holder read, this counts what it lets
    /// them do. It is hidden — and takes no room — when the file carries no admin secrets at all.
    private let adminLabel = UILabel()
    private let deviceLabelsSwitch = UISwitch()
    private let deviceLabelsCaption = UILabel()
    private let codeCaption = UILabel()
    private let codeBlock = UILabel()
    private let copyCodeButton = UIButton(type: .system)
    private let hintLabel = UILabel()
    private let warningLabel = UILabel()
    private let shareButton = UIButton(type: .system)
    private let copyBundleButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    /// PLAN.md 3.46 check 7: called when the bundle is handed off (share sheet completed, or its text copied).
    private let onHandOff: (() -> Void)?

    public init(result: SecutgAccountRuntime.ExportResult, rebuild: @escaping (Bool) -> SecutgAccountRuntime.ExportResult?,
                onHandOff: (() -> Void)? = nil) {
        self.result = result
        self.rebuild = rebuild
        self.onHandOff = onHandOff
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

        titleLabel.text = SecutgL10n.string("SecutgExportTitle")
        titleLabel.font = UIFont.boldSystemFont(ofSize: 20.0)
        codeCaption.text = SecutgL10n.string("SecutgExportCodeLabel")
        codeCaption.font = UIFont.boldSystemFont(ofSize: 15.0)
        codeBlock.font = UIFont.monospacedDigitSystemFont(ofSize: 19.0, weight: .semibold)
        codeBlock.textAlignment = .center
        codeBlock.backgroundColor = UIColor(white: 0.94, alpha: 1.0)
        codeBlock.layer.cornerRadius = 10.0
        codeBlock.layer.masksToBounds = true
        hintLabel.text = SecutgL10n.string("SecutgExportCodeHint")
        warningLabel.text = SecutgL10n.string("SecutgExportWarning")
        warningLabel.textColor = UIColor(red: 0.8, green: 0.15, blue: 0.15, alpha: 1.0)
        // PLAN.md 3.25.4 rule 2: default unchecked (= device labels included); UIAlertController has no room
        // for a real toggle, but this screen is a plain UIKit view already, so a genuine UISwitch fits here.
        deviceLabelsCaption.text = SecutgL10n.string("SecutgExportExcludeDeviceLabels")
        deviceLabelsCaption.font = UIFont.systemFont(ofSize: 15.0)
        deviceLabelsSwitch.isOn = false
        deviceLabelsSwitch.addTarget(self, action: #selector(deviceLabelsSwitchChanged), for: .valueChanged)

        adminLabel.font = UIFont.systemFont(ofSize: 15.0)

        for label in [titleLabel, summaryLabel, adminLabel, deviceLabelsCaption, codeCaption, hintLabel] { label.textColor = .black }
        codeBlock.textColor = .black
        for label in [titleLabel, summaryLabel, adminLabel, deviceLabelsCaption, codeCaption, codeBlock, hintLabel, warningLabel] {
            label.numberOfLines = 0
            scroll.addSubview(label)
        }
        scroll.addSubview(deviceLabelsSwitch)
        for (button, title, action) in [
            (shareButton, SecutgL10n.string("SecutgExportShare"), #selector(shareTapped)),
            (copyCodeButton, SecutgL10n.string("SecutgCopy"), #selector(copyCodeTapped)),
            (copyBundleButton, SecutgL10n.string("SecutgCopyKeyText"), #selector(copyBundleTapped)),
            (closeButton, SecutgL10n.string("SecutgClose"), #selector(closeTapped)),
        ] {
            button.setTitle(title, for: .normal)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.addTarget(self, action: action, for: .touchUpInside)
            scroll.addSubview(button)
        }
        applyResult()
    }

    /// Refreshes every label/button that reads off `result` — called on load and again whenever the device-labels
    /// switch triggers a fresh export.
    private func applyResult() {
        summaryLabel.text = SecutgL10n.string("SecutgExportSummary", [
            "scope": SecutgL10n.string(result.summary.scope == .all ? "SecutgScopeAll" : "SecutgScopeChat"),
            "chats": "\(result.summary.chatCount)",
            "masters": "\(result.summary.masterCount)",
        ])
        // PLAN.md 3.30 item 8: say out loud that this file also hands over the power to rekey those groups and
        // remove members from them — the manifest has always named the reading and never the rekeying. Only when
        // there is at least one: a line reading "0 groups" on every single-chat export would train the reader to
        // skip the manifest, which is the one thing it cannot afford. Re-read on every `applyResult` because the
        // device-labels switch rebuilds the whole export, and a stale count here would describe another file.
        adminLabel.isHidden = result.summary.adminChatCount == 0
        adminLabel.text = SecutgL10n.string("SecutgImportWithAdminKeys", ["count": "\(result.summary.adminChatCount)"])
        codeBlock.text = SecutgTransferExportController.wrap(result.code)
        copyCodeButton.setTitle(SecutgL10n.string("SecutgCopy"), for: .normal)
        copyBundleButton.setTitle(SecutgL10n.string("SecutgCopyKeyText"), for: .normal)
    }

    @objc private func deviceLabelsSwitchChanged() {
        includeDeviceLabels = !deviceLabelsSwitch.isOn
        guard let fresh = rebuild(includeDeviceLabels) else {
            deviceLabelsSwitch.isOn = !includeDeviceLabels   // roll back: the export screen must never show a stale code for the state actually on screen
            return
        }
        result = fresh
        applyResult()
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let inset: CGFloat = 24.0
        let width = layout.size.width - inset * 2.0
        scroll.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: layout.size)
        var y = layout.safeInsets.top + 32.0
        func place(_ view: UIView, height: CGFloat? = nil, gap: CGFloat = 14.0) {
            let fitted = height ?? view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            view.frame = CGRect(x: inset, y: y, width: width, height: fitted)
            y += fitted + gap
        }
        place(titleLabel)
        place(summaryLabel, gap: adminLabel.isHidden ? 14.0 : 8.0)
        // PLAN.md 3.30 item 8: nothing at all when the file carries no admin secrets, not an empty row
        if !adminLabel.isHidden {
            place(adminLabel)
        }
        deviceLabelsSwitch.sizeToFit()
        deviceLabelsSwitch.frame = CGRect(x: inset, y: y, width: deviceLabelsSwitch.frame.width, height: deviceLabelsSwitch.frame.height)
        deviceLabelsCaption.frame = CGRect(
            x: inset + deviceLabelsSwitch.frame.width + 10.0, y: y,
            width: width - deviceLabelsSwitch.frame.width - 10.0,
            height: deviceLabelsCaption.sizeThatFits(CGSize(width: width - deviceLabelsSwitch.frame.width - 10.0, height: .greatestFiniteMagnitude)).height)
        y += max(deviceLabelsSwitch.frame.height, deviceLabelsCaption.frame.height) + 18.0
        place(codeCaption, gap: 8.0)
        place(codeBlock, height: codeBlock.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 24.0, gap: 6.0)
        place(copyCodeButton, height: 40.0, gap: 8.0)
        place(hintLabel)
        place(warningLabel, gap: 22.0)
        place(shareButton, height: 48.0, gap: 6.0)
        place(copyBundleButton, height: 44.0, gap: 6.0)
        place(closeButton, height: 44.0)
        scroll.contentSize = CGSize(width: layout.size.width, height: y + layout.intrinsicInsets.bottom + 24.0)
    }

    /// 32 characters in eight groups read better as two lines of four.
    static func wrap(_ code: String) -> String {
        let groups = code.components(separatedBy: "-")
        guard groups.count == 8 else { return code }
        return groups[0..<4].joined(separator: "-") + "\n" + groups[4..<8].joined(separator: "-")
    }

    @objc private func copyCodeTapped() {
        UIPasteboard.general.string = result.code
        copyCodeButton.setTitle(SecutgL10n.string("SecutgClipboardHint"), for: .normal)
    }

    @objc private func copyBundleTapped() {
        UIPasteboard.general.string = result.bundle
        copyBundleButton.setTitle(SecutgL10n.string("SecutgClipboardHint"), for: .normal)
        onHandOff?()
    }

    /// Writes the bundle as `secutg-keys-<stamp>.secutg` into a temp folder and hands it to the system share sheet,
    /// so AirDrop to the other device works. The code itself deliberately never travels with it.
    @objc private func shareTapped() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("secutg-transfer", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(result.fileName)
            try Data(result.bundle.utf8).write(to: url, options: .atomic)
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.completionWithItemsHandler = { [onHandOff] _, completed, _, _ in
                if completed { onHandOff?() }
            }
            if let popover = activity.popoverPresentationController {
                popover.sourceView = shareButton
                popover.sourceRect = shareButton.bounds
            }
            SecutgTransfer.presentSystem(activity, over: self)
        } catch {
            shareButton.setTitle(SecutgL10n.string("SecutgOperationFailed", ["error": "\(error)"]), for: .normal)
        }
    }

    @objc private func closeTapped() {
        self.dismiss()
    }
}
