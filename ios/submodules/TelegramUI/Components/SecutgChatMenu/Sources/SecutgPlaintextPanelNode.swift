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

/// SECUTG (PLAN.md 3.30 rule 10): "the other side keeps sending plaintext", drawn.
///
/// **Why a header panel and not a dialog.** Web A floats this over the composer; the iOS equivalent of
/// that slot is not a modal but the strip of panels under the navigation bar — the one the report/spam
/// bar and the translation bar live in. A `UIAlertController` was the wrong shape twice over: it stops
/// the user mid-sentence to tell them something they cannot act on in one second, and once dismissed it
/// is gone, whereas this bar stays up for as long as the peer keeps sending plaintext and goes away by
/// itself the moment they encrypt again. It is also the only form that survives the user scrolling, which
/// a row in the message list (the shape 3.23 and 3.24 use) would not.
///
/// **Why it does not fight the other bars.** `HeaderPanelContainerComponent` stacks panels by
/// `orderIndex` rather than showing one at a time, so a pinned message, a translation offer and this can
/// all be up at once. That is what made the header strip the right mount point: the older
/// `ChatTitleAccessoryPanelNode` slot in `titlePanelForChatPresentationInterfaceState` is single-valued,
/// and putting a security warning there would mean a pinned message could silently suppress it.
///
/// The node itself only draws and reports taps; what the bar says is `SecutgCore.PlaintextPane` and what
/// the buttons do is `SecutgPlaintextPaneHost`.
public final class SecutgPlaintextPanelNode: ChatTitleAccessoryPanelNode {
    private struct Action {
        let title: String
        let action: SecutgPlaintextPaneHost.Action
        let isDestructive: Bool
    }

    private let context: AccountContext
    private let peerId: PeerId

    private let titleNode: ImmediateTextNode
    private var buttons: [(SecutgPlaintextPaneHost.Action, UIButton)] = []
    private var actions: [Action] = []

    private var strings: PresentationStrings?

    public init(context: AccountContext, peerId: PeerId) {
        self.context = context
        self.peerId = peerId

        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 2
        self.titleNode.textAlignment = .center

        super.init()

        self.addSubnode(self.titleNode)
    }

    /// Resolved on the main queue, where the panel is built, so the language table is never read from a
    /// background thread. All four keys already exist in the shared table — this bar adds no strings.
    private func reloadContent() {
        SecutgChatMenu.syncLanguage(context: self.context)
        self.actions = [
            Action(title: SecutgL10n.string("SecutgPlaintextPaneKeep"), action: .keep, isDestructive: false),
            Action(title: SecutgL10n.string("SecutgPlaintextPaneOff"), action: .off, isDestructive: true),
            Action(title: SecutgL10n.string("SecutgPlaintextPaneIgnore"), action: .ignore, isDestructive: false),
        ]
    }

    override public func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) -> LayoutResult {
        // The button titles are resolved once rather than per pass, so they have to be re-resolved when the
        // app's language changes under a chat that is already open — `SecutgL10n`'s table is switched from
        // the same presentation data this `strings` comes from.
        if self.actions.isEmpty || interfaceState.strings !== self.strings {
            self.strings = interfaceState.strings
            self.reloadContent()
            for (_, view) in self.buttons {
                view.removeFromSuperview()
            }
            self.buttons.removeAll()
        }

        let sideInset: CGFloat = 12.0
        let topInset: CGFloat = 8.0
        let bottomInset: CGFloat = 8.0
        let titleToButtonsSpacing: CGFloat = 4.0
        let buttonsHeight: CGFloat = 32.0
        let contentWidth = max(1.0, width - leftInset - rightInset - sideInset * 2.0)

        self.titleNode.attributedText = NSAttributedString(
            string: SecutgL10n.string("SecutgPlaintextPaneTitle"),
            font: Font.regular(14.0),
            textColor: interfaceState.theme.rootController.navigationBar.primaryTextColor
        )
        let titleSize = self.titleNode.updateLayout(CGSize(width: contentWidth, height: 100.0))
        // Frames are assigned rather than transitioned, as in the two panels this one sits beside
        // (`ChatToastAlertPanelNode`, `ChatReportPeerTitlePanelNode`): the strip animates the panel's own
        // height in and out, and animating the children inside that would only animate them from zero.
        self.titleNode.frame = CGRect(
            origin: CGPoint(x: leftInset + sideInset + floorToScreenPixels((contentWidth - titleSize.width) / 2.0), y: topInset),
            size: titleSize
        )

        if self.buttons.count != self.actions.count {
            for (_, view) in self.buttons {
                view.removeFromSuperview()
            }
            self.buttons.removeAll()
            for action in self.actions {
                let view = UIButton()
                view.titleLabel?.font = Font.regular(15.0)
                view.titleLabel?.adjustsFontSizeToFitWidth = true
                view.titleLabel?.minimumScaleFactor = 0.7
                view.setTitle(action.title, for: [])
                view.addTarget(self, action: #selector(self.buttonPressed(_:)), for: [.touchUpInside])
                self.view.addSubview(view)
                self.buttons.append((action.action, view))
            }
        }
        for (index, action) in self.actions.enumerated() {
            // The one destructive button is the only one of the three that changes anything; the other two
            // are answers about this session (see `SecutgPlaintextPaneHost.perform`).
            let color = action.isDestructive
                ? interfaceState.theme.chat.inputPanel.panelControlDestructiveColor
                : interfaceState.theme.rootController.navigationBar.accentTextColor
            let view = self.buttons[index].1
            view.setTitleColor(color, for: [])
            view.setTitleColor(color.withAlphaComponent(0.7), for: [.highlighted])
        }

        // Three buttons of equal width rather than sized to their titles: they are one question with three
        // answers, and the three translations differ enough in length that proportional widths would make
        // the same bar look like a different control in each language.
        let buttonWidth = floor(contentWidth / CGFloat(max(1, self.buttons.count)))
        let buttonsY = topInset + titleSize.height + titleToButtonsSpacing
        for index in 0 ..< self.buttons.count {
            self.buttons[index].1.frame = CGRect(
                origin: CGPoint(x: leftInset + sideInset + CGFloat(index) * buttonWidth, y: buttonsY),
                size: CGSize(width: buttonWidth, height: buttonsHeight)
            )
        }

        let panelHeight = buttonsY + buttonsHeight + bottomInset
        return LayoutResult(backgroundHeight: panelHeight, insetHeight: panelHeight, hitTestSlop: 0.0)
    }

    @objc private func buttonPressed(_ sender: UIButton) {
        for (action, view) in self.buttons where view === sender {
            SecutgPlaintextPaneHost.perform(action, context: self.context, peerId: self.peerId)
            return
        }
    }
}
