import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import LocalizedPeerData
import TelegramPresentationData
import SecutgCore

/// SECUTG (feature, 2026-09-28, PLAN.md 3.38.2; was 3.38.1): 群密码 on iOS — the admin's set / change / disable
/// dialogs (each sends ONE `GP1`, never a key), the unlock prompt, and the account-wide listener that drops a
/// group's local cache when its password policy turns on.
///
/// Every Argon2id call (set, change, unlock) runs on a background queue behind a 「正在处理…」 sheet: it takes
/// 64 MiB and a noticeable fraction of a second, which on the main thread is a frozen screen.
public enum SecutgGroupPassword {
    private static let workQueue = DispatchQueue(label: "secutg.grouppw", qos: .userInitiated)

    // MARK: menu

    enum MenuAction { case set, change, disable, unlock }

    /// Which entries the group menu offers (admin rule 1, plus — legacy — the way into history kept behind a
    /// 3.38.1 locked record). `isTelegramAdmin` is Telegram's own sense of admin.
    static func menuActions(status: SecutgChatStatus, keyMode: Rekey.KeyMode, isTelegramAdmin: Bool) -> [MenuAction] {
        guard !status.isPrivateChat else { return [] }
        var out: [MenuAction] = []
        // Scope of this batch: auto-mode groups only (3.38.1). The admin needs a key to rebuild from.
        if isTelegramAdmin && keyMode == .auto && status.hasKey {
            out += status.groupPassword.isActive ? [.change, .disable] : [.set]
        }
        if status.legacyGroupPasswordLocked { out.append(.unlock) }
        return out
    }

    static func title(_ action: MenuAction) -> String {
        switch action {
        case .set: return SecutgL10n.string("SecutgGroupPwSet")
        case .change: return SecutgL10n.string("SecutgGroupPwChange")
        case .disable: return SecutgL10n.string("SecutgGroupPwDisable")
        case .unlock: return SecutgL10n.string("SecutgGroupPwUnlock")
        }
    }

    static func run(_ action: MenuAction, context: AccountContext, peerId: PeerId, controller: ViewController) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        switch action {
        case .set:
            presentSetDialog(context: context, peerId: peerId, controller: controller, runtime: runtime, isChange: false)
        case .change:
            // Admin rule 4: this run must have opened the group before it may rebuild it.
            unlockFirst(context: context, peerId: peerId, controller: controller, runtime: runtime) {
                presentSetDialog(context: context, peerId: peerId, controller: controller, runtime: runtime, isChange: true)
            }
        case .disable:
            unlockFirst(context: context, peerId: peerId, controller: controller, runtime: runtime) {
                confirmDisable(context: context, peerId: peerId, controller: controller, runtime: runtime)
            }
        case .unlock:
            presentUnlockPrompt(controller: controller, runtime: runtime, peerId: peerId, context: context, legacy: true, completion: {})
        }
    }

    // MARK: set / change

    private static func presentSetDialog(context: AccountContext, peerId: PeerId, controller: ViewController,
                                         runtime: SecutgAccountRuntime, isChange: Bool, error: String? = nil) {
        let title = SecutgL10n.string(isChange ? "SecutgGroupPwChange" : "SecutgGroupPwSet")
        let warn = SecutgL10n.string("SecutgGroupPwWarn")
        let alert = UIAlertController(title: title, message: error.map { $0 + "\n\n" + warn } ?? warn, preferredStyle: .alert)
        for _ in 0..<2 {
            alert.addTextField { field in
                field.isSecureTextEntry = true
                field.placeholder = SecutgL10n.string("SecutgGroupPwEnterTitle")
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
            }
        }
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default, handler: { [weak controller, weak alert] _ in
            guard let controller else { return }
            let first = alert?.textFields?.first?.text ?? ""
            let second = alert?.textFields?.last?.text ?? ""
            if first != second {
                presentSetDialog(context: context, peerId: peerId, controller: controller, runtime: runtime, isChange: isChange,
                                 error: SecutgL10n.string("SecutgGroupPwMismatch"))
                return
            }
            if GroupPassword.validatePassword(first) != .ok {
                presentSetDialog(context: context, peerId: peerId, controller: controller, runtime: runtime, isChange: isChange,
                                 error: SecutgL10n.string("SecutgGroupPwTooShort"))
                return
            }
            let working = presentWorking(over: controller)
            workQueue.async {
                let built: GroupPasswordSession.PolicyBuilt?
                let failure: String?
                do {
                    built = try runtime.setGroupPassword(chatPeerId: peerId, password: first)
                    failure = nil
                } catch {
                    built = nil
                    failure = "\(error)"
                }
                DispatchQueue.main.async {
                    working.dismiss(animated: true, completion: {
                        guard let built else {
                            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgCreateFailed", ["error": failure ?? "-"]))
                            return
                        }
                        send(built, context: context, peerId: peerId)
                        SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgGroupPwAdopted"))
                    })
                }
            }
        }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    /// PLAN.md 3.38.2: the one `GP1`. When it turns the password on here, the local cache goes first (the admin's
    /// device adopts the policy too), so the new message is not swept with it.
    private static func send(_ built: GroupPasswordSession.PolicyBuilt, context: AccountContext, peerId: PeerId) {
        let post = {
            SecutgChatMenu.sendText(context: context, peerId: peerId, text: built.broadcast)
        }
        guard built.turnedOn else {
            post()
            return
        }
        let _ = (secutgDropLocalHistory(postbox: context.account.postbox, peerId: peerId)
        |> deliverOnMainQueue).startStandalone(completed: {
            post()
        })
    }

    // MARK: disable

    private static func confirmDisable(context: AccountContext, peerId: PeerId, controller: ViewController, runtime: SecutgAccountRuntime) {
        let title = SecutgL10n.string("SecutgGroupPwDisable")
        let alert = UIAlertController(title: title, message: SecutgL10n.string("SecutgGroupPwDisabledLine"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: title, style: .destructive, handler: { [weak controller] _ in
            guard let controller else { return }
            do {
                let built = try runtime.disableGroupPassword(chatPeerId: peerId)
                send(built, context: context, peerId: peerId)
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgGroupPwDisabledLine"))
            } catch {
                SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgCreateFailed", ["error": "\(error)"]))
            }
        }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    // MARK: unlock

    private static func unlockFirst(context: AccountContext, peerId: PeerId, controller: ViewController,
                                    runtime: SecutgAccountRuntime, then next: @escaping () -> Void) {
        guard runtime.needsGroupPassword(chatPeerId: peerId) else {
            next()
            return
        }
        presentUnlockPrompt(controller: controller, runtime: runtime, peerId: peerId, context: context, completion: next)
    }

    /// The dialog form of the unlock (menu, change / disable). The chat itself uses the full-screen page,
    /// `SecutgGroupPasswordGateView`.
    private static func presentUnlockPrompt(controller: ViewController, runtime: SecutgAccountRuntime, peerId: PeerId,
                                            context: AccountContext, legacy: Bool = false, error: String? = nil,
                                            completion: @escaping () -> Void) {
        let alert = UIAlertController(title: SecutgL10n.string("SecutgGroupPwEnterTitle"), message: error, preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgGroupPwUnlock"), style: .default, handler: { [weak controller, weak alert] _ in
            guard let controller else { return }
            let password = alert?.textFields?.first?.text ?? ""
            let working = presentWorking(over: controller)
            unlock(runtime: runtime, context: context, peerId: peerId, password: password, legacy: legacy) { message in
                working.dismiss(animated: true, completion: {
                    if let message {
                        presentUnlockPrompt(controller: controller, runtime: runtime, peerId: peerId, context: context,
                                            legacy: legacy, error: message, completion: completion)
                    } else {
                        completion()
                    }
                })
            }
        }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    /// Argon2id off the main thread. `completion` runs on the main queue with nil on success, or the sentence to
    /// show (「密码不对或数据已损坏」 / 「尝试次数过多…」).
    static func unlock(runtime: SecutgAccountRuntime, context: AccountContext, peerId: PeerId, password: String,
                       legacy: Bool = false, completion: @escaping (String?) -> Void) {
        workQueue.async {
            let result = runtime.unlockGroupPassword(chatPeerId: peerId, password: password, legacy: legacy)
            DispatchQueue.main.async {
                switch result {
                case .unlocked:
                    // Rows stored sealed (3.19) read their words at layout time and read 「需要群密码」 while the
                    // group was locked; lay them out again now. The undecryptable ones (legacy) are swept by
                    // `keysChanged` (3.17).
                    let _ = secutgRefreshSealedRows(postbox: context.account.postbox, peerId: peerId).startStandalone()
                    completion(nil)
                case .wrong, .noRecord:
                    completion(SecutgL10n.string("SecutgGroupPwWrong"))
                case let .tooMany(seconds):
                    completion(SecutgL10n.string("SecutgGroupPwTooMany", ["seconds": "\(seconds)"]))
                }
            }
        }
    }

    private static func presentWorking(over controller: ViewController) -> UIAlertController {
        let working = UIAlertController(title: SecutgL10n.string("SecutgGroupPwWorking"), message: nil, preferredStyle: .alert)
        SecutgChatMenu.presentSystem(working, over: controller)
        return working
    }

    // MARK: the password policy turned on → drop the local cache (PLAN.md 3.38.2)

    private static var listeners: [PeerId: Disposable] = [:]

    /// Account-wide, like `SecutgKeysChanged`: a `GP1` arrives whenever it arrives, not only while the group is on
    /// screen. Main queue only; idempotent.
    public static func install(context: AccountContext) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let accountPeerId = context.account.peerId
        listeners.removeValue(forKey: accountPeerId)?.dispose()
        listeners[accountPeerId] = (runtime.groupPasswordAdopted.signal() |> deliverOnMainQueue).start(next: { [weak context] chatPeerId in
            guard let context else { return }
            // Local only: the server still has every message, as `E1` ciphertext, and the history view fetches it
            // back through the hole this leaves.
            let _ = secutgDropLocalHistory(postbox: context.account.postbox, peerId: chatPeerId).startStandalone()
        })
    }
}

/// SECUTG (feature, 2026-09-28, PLAN.md 3.38.1 member rule 3): the password page that covers a locked group's
/// chat — group name, a password field and 〔解锁〕 — and nothing of the conversation. The navigation bar stays,
/// so the ordinary back button is the way out.
public final class SecutgGroupPasswordGateView: UIView, UITextFieldDelegate {
    private let context: AccountContext
    private let peerId: PeerId
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let field = UITextField()
    private let button = UIButton(type: .system)
    private let errorLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var busy = false

    private init(context: AccountContext, peerId: PeerId) {
        self.context = context
        self.peerId = peerId
        super.init(frame: .zero)
        let theme = context.sharedContext.currentPresentationData.with { $0 }.theme
        self.backgroundColor = theme.list.plainBackgroundColor

        titleLabel.font = UIFont.boldSystemFont(ofSize: 20)
        titleLabel.textColor = theme.list.itemPrimaryTextColor
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        hintLabel.font = UIFont.systemFont(ofSize: 15)
        hintLabel.textColor = theme.list.itemSecondaryTextColor
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.text = SecutgL10n.string("SecutgGroupPwLockedPreview")
        field.isSecureTextEntry = true
        field.borderStyle = .roundedRect
        field.placeholder = SecutgL10n.string("SecutgGroupPwEnterTitle")
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.delegate = self
        button.setTitle(SecutgL10n.string("SecutgGroupPwUnlock"), for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        button.tintColor = theme.list.itemAccentColor
        button.addTarget(self, action: #selector(unlockTapped), for: .touchUpInside)
        errorLabel.font = UIFont.systemFont(ofSize: 14)
        errorLabel.textColor = theme.list.itemDestructiveColor
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        spinner.hidesWhenStopped = true
        for view in [titleLabel, hintLabel, field, button, errorLabel, spinner] as [UIView] { addSubview(view) }

        let _ = (context.account.postbox.transaction { transaction -> Peer? in
            return transaction.getPeer(peerId)
        }
        |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
            guard let self else { return }
            self.titleLabel.text = peer.map { EnginePeer($0).compactDisplayTitle } ?? SecutgL10n.string("SecutgGroupPwEnterTitle")
            self.setNeedsLayout()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Creates / positions the page while the group is locked; returns nil (removing any existing page) otherwise.
    /// Called from `ChatController.containerLayoutUpdated` next to the floating lock button.
    public static func update(existing: SecutgGroupPasswordGateView?, in hostView: UIView, context: AccountContext,
                              peerId: PeerId?, layout: ContainerViewLayout, navigationBarHeight: CGFloat) -> SecutgGroupPasswordGateView? {
        guard let peerId, let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId),
              runtime.needsGroupPassword(chatPeerId: peerId) else {
            existing?.removeFromSuperview()
            return nil
        }
        let gate: SecutgGroupPasswordGateView
        if let existing, existing.peerId == peerId {
            gate = existing
        } else {
            existing?.removeFromSuperview()
            SecutgChatMenu.syncLanguage(context: context)
            gate = SecutgGroupPasswordGateView(context: context, peerId: peerId)
        }
        if gate.superview !== hostView { hostView.addSubview(gate) }
        hostView.bringSubviewToFront(gate)
        gate.frame = CGRect(x: 0, y: navigationBarHeight, width: layout.size.width,
                            height: max(0, layout.size.height - navigationBarHeight))
        return gate
    }

    /// SECUTG-HOOK (fix, 2026-09-29, review H1): `update` above only runs from `containerLayoutUpdated`, which the
    /// system calls for rotation / keyboard / navigation-bar changes — not when a `GP1` arrives while the chat is
    /// open, so the page used to appear one layout event late. `ChatController` installs this while the chat is
    /// visible: the runtime reports every move of this peer's gate (a policy applied, an unlock) and the controller
    /// requests a layout, the one road to `update`. Private chats are never gated, so nothing is installed for them.
    public static func observeLockState(context: AccountContext, peerId: PeerId, onChange: @escaping () -> Void) -> Disposable {
        guard peerId.namespace == Namespaces.Peer.CloudGroup || peerId.namespace == Namespaces.Peer.CloudChannel,
              let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return EmptyDisposable }
        return (runtime.groupPasswordChanged.signal()
        |> filter { $0 == peerId }
        |> deliverOnMainQueue).start(next: { _ in onChange() })
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 48, 360)
        let x = (bounds.width - width) / 2
        var y: CGFloat = 48
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        titleLabel.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y += titleHeight + 12
        let hintHeight = hintLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        hintLabel.frame = CGRect(x: x, y: y, width: width, height: hintHeight)
        y += hintHeight + 24
        field.frame = CGRect(x: x, y: y, width: width, height: 44)
        y += 44 + 16
        button.frame = CGRect(x: x, y: y, width: width, height: 44)
        spinner.center = CGPoint(x: bounds.midX, y: y + 22)
        y += 44 + 12
        let errorHeight = errorLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        errorLabel.frame = CGRect(x: x, y: y, width: width, height: errorHeight)
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        unlockTapped()
        return true
    }

    @objc private func unlockTapped() {
        guard !busy, let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        busy = true
        errorLabel.text = SecutgL10n.string("SecutgGroupPwWorking")
        button.isHidden = true
        spinner.startAnimating()
        setNeedsLayout()
        SecutgGroupPassword.unlock(runtime: runtime, context: context, peerId: peerId, password: field.text ?? "") { [weak self] message in
            guard let self else { return }
            self.busy = false
            self.spinner.stopAnimating()
            self.button.isHidden = false
            if let message {
                self.errorLabel.text = message
                self.field.text = ""
                self.setNeedsLayout()
            } else {
                self.field.resignFirstResponder()
                self.removeFromSuperview()
            }
        }
    }
}
