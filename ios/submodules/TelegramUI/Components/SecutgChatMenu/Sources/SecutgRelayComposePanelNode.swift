import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatPresentationInterfaceState
import LegacyChatHeaderPanelComponent
import SecutgCore
import SecutgRelay

/// SECUTG-HOOK (PLAN.md 3.48.4 gap a part 1): the compose-time "⇄ 通过中转发送 · {policy} ✎ ✕" tag — up exactly
/// when `SecutgRelayComposeHost.isDue` says the send about to happen (manual or auto) will go through a relay.
/// Modeled directly on `SecutgPlaintextPanelNode` (same header-strip slot and for the same reasons: it must
/// survive scrolling, must not be a modal — the draft is still in the box — and stacks with the other secuTG
/// bars instead of replacing them).
///
/// ✎ reuses `SecutgRelayChatController`'s own per-chat policy screen rather than building a second picker UI.
/// ✕ sets a one-shot "skip relay for the very next send" override (`SecutgRelayComposeState`); it does not
/// change this chat's policy, only this one upcoming send, matching PLAN.md 3.48.4's "一次性" framing for the
/// tag's own buttons (distinct from the lock-menu's "本聊天从不走中转", which is a standing choice).
public final class SecutgRelayComposePanelNode: ChatTitleAccessoryPanelNode {
    private let context: AccountContext
    private let peerId: PeerId
    private let controller: () -> ViewController?

    private let titleNode: ImmediateTextNode
    private let editButton: UIButton
    private let cancelButton: UIButton

    private var strings: PresentationStrings?

    public init(context: AccountContext, peerId: PeerId, controller: @escaping () -> ViewController?) {
        self.context = context
        self.peerId = peerId
        self.controller = controller

        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.textAlignment = .natural
        self.titleNode.isUserInteractionEnabled = false

        self.editButton = UIButton(type: .system)
        self.cancelButton = UIButton(type: .system)

        super.init()

        self.addSubnode(self.titleNode)

        self.editButton.setTitle("✎", for: [])
        self.cancelButton.setTitle("✕", for: [])
        self.editButton.titleLabel?.font = Font.regular(17.0)
        self.cancelButton.titleLabel?.font = Font.regular(17.0)
        self.editButton.addTarget(self, action: #selector(self.editPressed), for: [.touchUpInside])
        self.cancelButton.addTarget(self, action: #selector(self.cancelPressed), for: [.touchUpInside])
        self.view.addSubview(self.editButton)
        self.view.addSubview(self.cancelButton)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) -> LayoutResult {
        self.strings = interfaceState.strings
        SecutgChatMenu.syncLanguage(context: self.context)

        let sideInset: CGFloat = 12.0
        let topInset: CGFloat = 8.0
        let bottomInset: CGFloat = 8.0
        let buttonSize: CGFloat = 28.0
        let buttonSpacing: CGFloat = 4.0
        let titleToButtonsSpacing: CGFloat = 8.0

        let textColor = interfaceState.theme.rootController.navigationBar.primaryTextColor
        let accentColor = interfaceState.theme.rootController.navigationBar.accentTextColor
        self.editButton.setTitleColor(accentColor, for: [])
        self.cancelButton.setTitleColor(interfaceState.theme.chat.inputPanel.panelControlDestructiveColor, for: [])

        // Any failure resolving the label falls back to the bare tag text (PLAN.md 3.48.0 rule 6) — this panel
        // is never due at all unless `SecutgRelayComposeHost.isDue` already said yes, so a label failure here is
        // cosmetic only, never a reason to hide the tag or crash.
        let policyLabel = SecutgRelayComposeHost.policyLabel(context: self.context, peerId: self.peerId)
        self.titleNode.attributedText = NSAttributedString(
            string: SecutgL10n.string("SecutgRelayComposeTag", ["policy": policyLabel]),
            font: Font.regular(14.0),
            textColor: textColor
        )

        let buttonsWidth = buttonSize * 2 + buttonSpacing
        let contentWidth = max(1.0, width - leftInset - rightInset - sideInset * 2.0)
        let titleWidth = max(1.0, contentWidth - buttonsWidth - titleToButtonsSpacing)
        let titleSize = self.titleNode.updateLayout(CGSize(width: titleWidth, height: 44.0))

        let rowHeight = max(titleSize.height, buttonSize)
        let rowY = topInset

        self.titleNode.frame = CGRect(
            origin: CGPoint(x: leftInset + sideInset, y: rowY + floor((rowHeight - titleSize.height) / 2.0)),
            size: titleSize
        )

        let buttonsOriginX = leftInset + sideInset + titleWidth + titleToButtonsSpacing
        self.editButton.frame = CGRect(origin: CGPoint(x: buttonsOriginX, y: rowY + floor((rowHeight - buttonSize) / 2.0)), size: CGSize(width: buttonSize, height: buttonSize))
        self.cancelButton.frame = CGRect(origin: CGPoint(x: buttonsOriginX + buttonSize + buttonSpacing, y: rowY + floor((rowHeight - buttonSize) / 2.0)), size: CGSize(width: buttonSize, height: buttonSize))

        let panelHeight = topInset + rowHeight + bottomInset
        return LayoutResult(backgroundHeight: panelHeight, insetHeight: panelHeight, hitTestSlop: 0.0)
    }

    @objc private func editPressed() {
        guard let controller = self.controller() else { return }
        controller.push(SecutgRelayChatController.controller(context: self.context, peerId: self.peerId))
    }

    @objc private func cancelPressed() {
        SecutgRelayComposeState.setSkipNext(peerId: self.peerId)
    }
}
