import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatPresentationInterfaceState
import LegacyChatHeaderPanelComponent
import SecutgCore

/// SECUTG (PLAN.md 3.41): 「没有钥匙时禁止发送」 — the live half of the refusal, on this client.
///
/// The rule is `SecutgCore.KeyRequired` (pure, under test, byte-identical with macOS); the flag and the send gate
/// are `SecutgAccountRuntime` (`prepareOutgoing`, `refusesForWantOfKey`, `setKeyRequired`). What lives here is
/// what only the UI layer can do: remember which chats have a refusal standing so the notice is drawn, ask the gate
/// *before* a composer send is enqueued so the draft stays in the box (3.41.2 草稿保留), and run the notice's two
/// buttons.
///
/// **One notice per chat at a time** (3.41.3): a refusal raises the chat's flag here; a second refusal in the same
/// chat finds it raised and changes nothing. It comes down when the chat gains a key or the flag is turned off —
/// `isDue` re-asks the runtime on every layout pass and lowers it by itself — or when 〔本聊天允许明文〕 is tapped.
public final class SecutgKeyRequiredNoticeState {
    public static let shared = SecutgKeyRequiredNoticeState()

    private let lock = NSLock()
    private var counter: Int32 = 0
    private let revisionPromise = ValuePromise<Int32>(0, ignoreRepeated: false)
    /// `account:chat` keys whose refusal notice is up.
    private var raised: Set<String> = []
    /// One live listener per account. Main queue only.
    private static var listeners: [PeerId: Disposable] = [:]

    private init() {
    }

    /// Bumped whenever a notice goes up or comes down. `ChatControllerImpl` folds it into a layout request, which
    /// is what draws the header strip this notice lives in.
    public var revision: Signal<Int32, NoError> {
        return self.revisionPromise.get()
    }

    public func invalidate() {
        self.lock.lock()
        self.counter &+= 1
        let value = self.counter
        self.lock.unlock()
        self.revisionPromise.set(value)
    }

    fileprivate func raise(key: String) {
        self.lock.lock()
        let inserted = self.raised.insert(key).inserted
        self.lock.unlock()
        if inserted {
            self.invalidate()
        }
    }

    /// `announce`: whether the layout that draws the strip should be asked for again. False from inside a layout
    /// pass (`isDue`), which is already drawing the answer.
    fileprivate func lower(key: String, announce: Bool) {
        self.lock.lock()
        let removed = self.raised.remove(key) != nil
        self.lock.unlock()
        if removed, announce {
            self.invalidate()
        }
    }

    fileprivate func isRaised(key: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.raised.contains(key)
    }

    /// Installs this account's listener for the lifetime of the account (`AccountContext` init, like
    /// `SecutgKeysChanged.install`): the send hook refuses wherever a message came from — the share sheet, a forward,
    /// an edit — and the chat on screen reads the answer when it next lays out. Idempotent per account.
    public static func install(context: AccountContext) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let accountPeerId = context.account.peerId
        listeners.removeValue(forKey: accountPeerId)?.dispose()
        listeners[accountPeerId] = (runtime.keyRequiredRefusals.signal() |> deliverOnMainQueue).start(next: { chatPeerId in
            shared.raise(key: SecutgKeyRequiredHost.key(accountPeerId: accountPeerId, peerId: chatPeerId))
        })
    }
}

/// The notice's view of the world: whether it belongs above this chat's composer, and what its buttons do.
public enum SecutgKeyRequiredHost {
    static func key(accountPeerId: PeerId, peerId: PeerId) -> String {
        return "\(accountPeerId.toInt64()):\(peerId.toInt64())"
    }

    /// The composer's pre-check (PLAN.md 3.41.2): true when this send must not be enqueued — the runtime has judged
    /// the messages by the same rule `prepareOutgoing` applies, and the refusal has been reported, so the notice is
    /// on its way up. Every `EnqueueMessage` is user content: a message's own text is what the gate reads (empty
    /// for media, a sticker, a voice note), and a forward is content whatever it carries.
    public static func refuse(context: AccountContext, peerId: PeerId, messages: [EnqueueMessage]) -> Bool {
        guard peerId.namespace != Namespaces.Peer.SecretChat, !messages.isEmpty,
              let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return false }
        for message in messages {
            let text: String
            switch message {
            case let .message(messageText, _, _, _, _, _, _, _, _, _):
                text = messageText
            case .forward:
                text = ""
            }
            if runtime.refusesForWantOfKey(chatPeerId: peerId, text: text) {
                runtime.reportKeyRequiredRefusal(chatPeerId: peerId)
                return true
            }
        }
        return false
    }

    /// Whether the notice belongs on screen in this chat right now. Read from `ChatControllerNode.updateLayout`, so
    /// the two in-memory checks go first and the runtime is only asked for a chat with a refusal standing.
    public static func isDue(context: AccountContext, peerId: PeerId) -> Bool {
        guard peerId.namespace != Namespaces.Peer.SecretChat else { return false }
        let key = key(accountPeerId: context.account.peerId, peerId: peerId)
        guard SecutgKeyRequiredNoticeState.shared.isRaised(key: key) else { return false }
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId),
              runtime.isRefusingWithoutKey(chatPeerId: peerId) else {
            // A key arrived, or the flag went off: the notice has nothing left to say.
            SecutgKeyRequiredNoticeState.shared.lower(key: key, announce: false)
            return false
        }
        return true
    }

    // MARK: what the buttons do (PLAN.md 3.41.3)

    public enum Action: Equatable {
        /// 〔去配对 / 导入钥匙〕: opens the lock menu, which offers whatever road this chat has to a key.
        case goPair
        /// 〔本聊天允许明文〕: turns the flag off for this chat. Deliberately does **not** resend — the user taps send
        /// again, knowing what will go out.
        case allowPlain
    }

    public static func perform(_ action: Action, context: AccountContext, peerId: PeerId, controller: ViewController?, sourceView: UIView?) {
        switch action {
        case .goPair:
            guard let controller, let sourceView else { return }
            SecutgChatMenu.presentSheet(context: context, peerId: peerId, controller: controller, sourceView: sourceView)
        case .allowPlain:
            SecutgHookRegistry.shared.runtime(for: context.account.peerId)?.setKeyRequired(chatPeerId: peerId, enabled: false)
            SecutgKeyRequiredNoticeState.shared.lower(key: key(accountPeerId: context.account.peerId, peerId: peerId), announce: true)
        }
    }
}

/// The notice itself: one sentence (`SecutgKeyRequiredBlocked`) and the two answers.
///
/// Mounted where the 3.30 plaintext bar is mounted, and for the same reasons (`SecutgPlaintextPanelNode`): the
/// header strip under the navigation bar is this client's slot for "something about this chat you should know",
/// it stacks with the pinned-message and translation bars instead of fighting them, it survives scrolling, and it
/// is not a modal — the user is mid-sentence, and the draft they were about to send is still in the box. PLAN.md
/// 3.41.3 asks for the strip *above the composer*; on this client that slot is the input's accessory panel, which
/// is single-valued and belongs to reply / edit / forward previews, so the header strip is the honest equivalent.
public final class SecutgKeyRequiredPanelNode: ChatTitleAccessoryPanelNode {
    private struct Action {
        let title: String
        let action: SecutgKeyRequiredHost.Action
        let isDestructive: Bool
    }

    private let context: AccountContext
    private let peerId: PeerId
    private let controller: () -> ViewController?

    private let titleNode: ImmediateTextNode
    private var buttons: [(SecutgKeyRequiredHost.Action, UIButton)] = []
    private var actions: [Action] = []

    private var strings: PresentationStrings?

    public init(context: AccountContext, peerId: PeerId, controller: @escaping () -> ViewController?) {
        self.context = context
        self.peerId = peerId
        self.controller = controller

        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 3
        self.titleNode.textAlignment = .center

        super.init()

        self.addSubnode(self.titleNode)
    }

    /// Resolved on the main queue, where the panel is built, so the language table is never read from a
    /// background thread. All three keys exist in the shared table (generated for PLAN.md 3.41).
    private func reloadContent() {
        SecutgChatMenu.syncLanguage(context: self.context)
        self.actions = [
            Action(title: SecutgL10n.string("SecutgKeyRequiredGoPair"), action: .goPair, isDestructive: false),
            Action(title: SecutgL10n.string("SecutgKeyRequiredAllowPlain"), action: .allowPlain, isDestructive: true),
        ]
    }

    override public func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) -> LayoutResult {
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
            string: SecutgL10n.string("SecutgKeyRequiredBlocked"),
            font: Font.regular(14.0),
            textColor: interfaceState.theme.rootController.navigationBar.primaryTextColor
        )
        let titleSize = self.titleNode.updateLayout(CGSize(width: contentWidth, height: 120.0))
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
            // 〔本聊天允许明文〕 is the one answer that changes anything, and what it changes is a protection.
            let color = action.isDestructive
                ? interfaceState.theme.chat.inputPanel.panelControlDestructiveColor
                : interfaceState.theme.rootController.navigationBar.accentTextColor
            let view = self.buttons[index].1
            view.setTitleColor(color, for: [])
            view.setTitleColor(color.withAlphaComponent(0.7), for: [.highlighted])
        }

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
            SecutgKeyRequiredHost.perform(action, context: self.context, peerId: self.peerId, controller: self.controller(), sourceView: sender)
            return
        }
    }
}
