import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import AccountContext

/// SECUTG: floating lock button pinned to the chat's top-right corner. Shows the chat's encryption state and
/// opens the secuTG action sheet. Created lazily from ChatController.containerLayoutUpdated.
public final class SecutgFloatingButton: UIButton {
    /// `#e53935` at 85%, the one "danger" red of PLAN.md 3.26 rule 3 / 3.28 rule 3. Named here, on the older
    /// of the two buttons, so the 3.28 emergency-wipe button uses the same value rather than a second copy of
    /// it that can drift — the two are meant to read as one visual language (Android does the same with
    /// `SecutgFloatingButton.NO_KEY_RED`).
    public static let dangerRed = UIColor(red: 0.9, green: 0.22, blue: 0.21, alpha: 0.85)

    private let context: AccountContext
    private let peerId: PeerId
    private weak var controller: ViewController?
    /// 2026-10-08 user: draggable, remembered. See `SecutgDraggable`.
    private var drag: SecutgDraggable?

    private init(context: AccountContext, peerId: PeerId, controller: ViewController) {
        self.context = context
        self.peerId = peerId
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        self.layer.cornerRadius = 22
        self.backgroundColor = SecutgFloatingButton.dangerRed
        self.titleLabel?.font = UIFont.systemFont(ofSize: 22)
        self.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        self.accessibilityLabel = "Si4Gram" // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
        self.drag = SecutgDraggable(button: self)
        self.refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Creates / positions the button for a peer chat; returns nil (and removes an existing one) when not applicable.
    public static func update(existing: SecutgFloatingButton?, in hostView: UIView, context: AccountContext, peerId: PeerId?, controller: ViewController, layout: ContainerViewLayout, navigationBarHeight: CGFloat) -> SecutgFloatingButton? {
        guard let peerId, peerId.namespace != Namespaces.Peer.SecretChat, SecutgHookRegistry.shared.runtime(for: context.account.peerId) != nil else {
            existing?.removeFromSuperview()
            return nil
        }
        let button: SecutgFloatingButton
        if let existing, existing.peerId == peerId {
            button = existing
        } else {
            existing?.removeFromSuperview()
            button = SecutgFloatingButton(context: context, peerId: peerId, controller: controller)
        }
        if button.superview !== hostView {
            hostView.addSubview(button)
        }
        hostView.bringSubviewToFront(button)
        let defaultFrame = CGRect(x: layout.size.width - layout.safeInsets.right - 44 - 10, y: navigationBarHeight + 10, width: 44, height: 44)
        button.frame = button.drag?.frame(default: defaultFrame, key: "lock_chat", layout: layout, controller: controller) ?? defaultFrame
        button.refresh()
        return button
    }

    /// Distinct from `dangerRed`/the green/orange used below (fix B1): a G2 auto-mode group's key
    /// travels the chat in the clear, so its indicator must never share a color family with the
    /// genuinely-encrypted states.
    private static let obfuscatedGray = UIColor(red: 0.42, green: 0.45, blue: 0.5, alpha: 0.85)

    public func refresh() {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let status = runtime.status(chatPeerId: peerId)
        let glyph: String
        // SECUTG-HOOK (fix B1): PLAN.md 3.35 — a G2 auto-mode group's key is broadcast in the clear
        // (obfuscated, not encrypted; Telegram itself can read it), unlike a real private-chat
        // pairing or a manual/当面-mode group. Checked first, before any of the lock/warning/key
        // branches below, so a G2 group always gets this one glyph regardless of rekey-due or
        // encryption-switch state — never the green lock those branches would otherwise give it.
        // Private chats (`!isPrivateChat` excludes them) and manual-mode groups (`keyMode != .auto`)
        // are untouched: they fall straight through to the unchanged branches below.
        let isObfuscatedGroup = !status.isPrivateChat && status.keyMode == .auto
        if isObfuscatedGroup {
            glyph = "\u{1F6E1}\u{FE0F}" // shield: PLAN.md 3.35.8's "obfuscated, not confidential to Telegram"
            self.backgroundColor = SecutgFloatingButton.obfuscatedGray
        } else if status.hasKeyOrV2 && status.isRekeyDue {
            glyph = "\u{26A0}\u{FE0F}"
            self.backgroundColor = UIColor(red: 0.98, green: 0.55, blue: 0.0, alpha: 0.85)
        } else if status.isEncryptedOrV2 && status.hasKeyOrV2 {
            // PLAN.md 3.26 rule 3: green has to mean what `prepareOutgoing` means — the switch AND a
            // usable key. The switch on its own encrypts nothing; the send path refuses for want of a key.
            // SECUTG-HOOK (fix, 2026-09-27): `hasKeyOrV2`/`isEncryptedOrV2` rather than `hasKey`/
            // `encryptionEnabled` — a chat paired entirely through v2 (no v1 record) used to sit on the
            // red 🔑 branch below while a real v2 binding was actively encrypting every message.
            glyph = "\u{1F512}"
            self.backgroundColor = UIColor(red: 0.0, green: 0.78, blue: 0.24, alpha: 0.85)
        } else if status.hasKeyOrV2 {
            glyph = "\u{1F513}"
            self.backgroundColor = SecutgFloatingButton.dangerRed
        } else {
            glyph = "\u{1F511}"
            self.backgroundColor = SecutgFloatingButton.dangerRed
        }
        self.accessibilityLabel = isObfuscatedGroup ? SecutgL10n.string("SecutgG2NoConfidentiality") : "Si4Gram" // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
        self.setTitle(glyph, for: .normal)
    }

    @objc private func tapped() {
        guard let controller else { return }
        SecutgChatMenu.presentSheet(context: context, peerId: peerId, controller: controller, sourceView: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
    }
}
