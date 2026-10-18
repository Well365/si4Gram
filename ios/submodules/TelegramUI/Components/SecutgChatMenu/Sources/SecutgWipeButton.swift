import Foundation
import UIKit
import Display
import TelegramCore
import AccountContext

/// SECUTG: the emergency wipe's own floating button (PLAN.md 3.28).
///
/// 3.16 put the wipe first in the settings page and said why: "这是唯一一个需要在慌乱中不用找就能点到的功能".
/// On iOS it was not reachable that way at all — the only paths to it were the secuTG settings group inside
/// the profile screen, and the per-chat "…" menu. Both are several taps deep, and one of them requires having
/// picked a chat first. 3.28 is the fix, and it is deliberately shaped like the 3.26 lock button: a floating
/// circle in a fixed corner, no menu in front of it.
///
/// The two buttons are **not** the same button and must not be confused:
///
/// * the 3.26 `SecutgFloatingButton` is per-chat — encryption is a property of a conversation, so it lives
///   inside `ChatController` and changes colour and glyph with that chat's state;
/// * this one is device-level — "这是设备级的动作，不是某个聊天的动作". It appears on the chat list *and*
///   inside every chat, but it is the same button in both: it never changes what it shows, and what it does
///   never depends on which chat happens to be open. Being in a chat is simply where people are when they
///   need it; a wipe that can only be reached by first backing out to the home screen is one that is not
///   reachable "不用找就能点到".
///
/// **Rule 2**: the only gate is this account's secuTG runtime being ready; once it is, the button is simply
/// always there. **Rule 3**: 🆘 on `SecutgFloatingButton.dangerRed` (`#e53935` at 85%), both fixed forever —
/// this button only ever does one thing, so it has no second state to show. **Rule 5**: no text on the button;
/// `SecutgWipeTitle` is the accessibility label, which is the only place it is named.
///
/// **Rule 4 is the important one.** Tapping this runs `SecutgWipeSettings.tapWipeRow`, the exact function the
/// settings page's red "紧急擦除" row runs — which is where `wipeNeedsConfirmation` is consulted and where the
/// 3.16 confirmation dialog is raised. There is deliberately no "should I confirm first?" test in this file.
/// A second copy of that decision is precisely what 3.28 rule 4 (and 3.24.7 rule 2 before it) warns about: the
/// two copies drift, and the half that drifts here is the half that decides whether an irreversible action
/// stops to ask. This button adds a trigger, not behaviour.
public final class SecutgWipeButton: UIButton {
    private static let size: CGFloat = 44.0
    /// Inset from the screen edge, and the gap below the host's own header — the same 10pt the 3.26
    /// button keeps below the chat's navigation bar, so the two sit in visually identical corners.
    private static let margin: CGFloat = 10.0

    /// Which side the button hangs from.
    ///
    /// On the chat list it is alone, so it takes the trailing corner the 3.26 lock button uses in a chat.
    /// Inside a chat that corner is already taken — by that very lock button — so the wipe moves to the
    /// leading corner and the two sit opposite each other. That mirroring is deliberate: they are the two
    /// most consequential controls in the app and they do opposite things, so a tap made in a hurry must
    /// not be able to hit the wrong one by being in the habit of reaching for the same corner.
    public enum Edge {
        case leading
        case trailing
    }

    private let context: AccountContext
    private weak var controller: ViewController?
    /// 2026-10-08 user: draggable, remembered per screen. See `SecutgDraggable`.
    private var drag: SecutgDraggable?

    private init(context: AccountContext, controller: ViewController) {
        self.context = context
        self.controller = controller
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: SecutgWipeButton.size, height: SecutgWipeButton.size))
        self.layer.cornerRadius = SecutgWipeButton.size / 2.0
        self.backgroundColor = SecutgFloatingButton.dangerRed
        self.titleLabel?.font = UIFont.systemFont(ofSize: 22.0)
        // Rule 3: the glyph is fixed. Nothing anywhere else in this file sets a title or a background colour.
        self.setTitle("\u{1F198}", for: .normal)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
        self.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        self.drag = SecutgDraggable(button: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Creates / positions the button. Returns nil (removing any existing one) while this account has no
    /// secuTG runtime — rule 2's single gate, and the same one `SecutgFloatingButton.update` applies.
    ///
    /// `navigationBarHeight` is the host's own header height: the button hangs just below it, which is
    /// where Web pins it relative to `LeftMainHeader` and where Android pins it relative to `DialogsActivity`'s
    /// action bar. Call this from the host controller's layout pass; it is idempotent.
    ///
    /// `edge` defaults to `.trailing`, which is where the chat list puts it; a chat passes `.leading` so it
    /// lands opposite that chat's lock button. See `Edge`.
    public static func update(existing: SecutgWipeButton?, in hostView: UIView, context: AccountContext, controller: ViewController, layout: ContainerViewLayout, navigationBarHeight: CGFloat, edge: Edge = .trailing) -> SecutgWipeButton? {
        guard SecutgHookRegistry.shared.runtime(for: context.account.peerId) != nil else {
            existing?.removeFromSuperview()
            return nil
        }
        let button = existing ?? SecutgWipeButton(context: context, controller: controller)
        button.controller = controller
        if button.superview !== hostView {
            hostView.addSubview(button)
        }
        hostView.bringSubviewToFront(button)
        // Rule 5: the label is the only description this control has, so it is refreshed with the language
        // rather than frozen at the moment the button happened to be built.
        SecutgChatMenu.syncLanguage(context: context)
        button.accessibilityLabel = SecutgL10n.string("SecutgWipeTitle")
        let x: CGFloat
        switch edge {
        case .leading:
            x = layout.safeInsets.left + SecutgWipeButton.margin
        case .trailing:
            x = layout.size.width - layout.safeInsets.right - SecutgWipeButton.size - SecutgWipeButton.margin
        }
        let defaultFrame = CGRect(
            x: x,
            y: navigationBarHeight + SecutgWipeButton.margin,
            width: SecutgWipeButton.size, height: SecutgWipeButton.size)
        // Each screen keeps its own spot: the chat (leading edge) one, and the chat list / profile / contacts
        // (trailing edge) one per host type.
        let key = edge == .leading ? "sos_chat" : "sos_\(type(of: controller))"
        button.frame = button.drag?.frame(default: defaultFrame, key: key, layout: layout, controller: controller) ?? defaultFrame
        return button
    }

    @objc private func tapped() {
        guard let controller else { return }
        // Rule 4: the existing chain, whole. `tapWipeRow` is what honours `wipeNeedsConfirmation` and what
        // raises the 3.16 confirmation dialog; this file must never decide either of those for itself.
        SecutgWipeSettings.tapWipeRow(context: self.context, controller: controller)
    }
}
