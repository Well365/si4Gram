import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import SecutgCore

/// SECUTG (PLAN.md 3.23): what gets said above the first message of somebody you have never answered.
///
/// Three things it deliberately is not:
///
/// - **Not a banner.** It is a row in the message list, above the first message and below the chat-info
///   block, and it scrolls away (PLAN.md 3.23.2). When a stranger writes first the chat holds one
///   message, so this sits right beside it at the moment the user is deciding whether to answer; in a
///   chat that is a year old it is at the top, out of sight, because that judgement was made long ago.
///   A permanent banner cannot manage the second half, and a warning that is always there is not a
///   warning (3.23.5).
/// - **Not a verdict.** Two facts — in your contacts or not, how many groups you share — and then the
///   judgement goes straight back to the reader. No common groups is not evidence of a scam (every new
///   friend starts there), and common groups are not evidence of safety (joining groups is how people
///   get found), so neither sentence is allowed to sound like a conclusion (3.23.5).
/// - **Not a lookup service.** No reputation database, no blocklist, no third party: everything said
///   here is something Telegram already told this device (3.23.6). Nothing is asked for until [Check]
///   is tapped — see `SecutgStrangerNoticeHost.perform`.
public final class SecutgStrangerNoticeItem: ListViewItem {
    struct Button {
        let title: String
        let action: SecutgStrangerNoticeHost.Action
    }

    /// Everything the node draws, resolved once here — on the main queue, where the entries are built —
    /// so `asyncLayout` never touches the language table from a background thread.
    struct Content {
        let text: String
        let buttons: [Button]
    }

    fileprivate let context: AccountContext
    fileprivate let peerId: PeerId
    fileprivate let presentationData: ChatPresentationData
    fileprivate let content: Content

    public init(
        context: AccountContext,
        peerId: PeerId,
        notice: StrangerNotice.Notice,
        presentationData: ChatPresentationData
    ) {
        self.context = context
        self.peerId = peerId
        self.presentationData = presentationData
        SecutgChatMenu.syncLanguage(context: context)
        self.content = SecutgStrangerNoticeItem.content(notice: notice)
    }

    static func content(notice: StrangerNotice.Notice) -> Content {
        func text(_ key: String, _ arguments: [String: String] = [:]) -> String {
            return SecutgL10n.string(key, arguments)
        }

        switch notice {
        case .hidden:
            // Unreachable: the entry is only built when the notice is not hidden. A total switch
            // beats a precondition here — an empty row is a cosmetic bug, a crash is not.
            return Content(text: "", buttons: [])
        case .ask:
            // PLAN.md 3.23.3: a question, not a filled-in number. The lookup is behind this tap because
            // asking for it tells the server who is being scrutinised (3.23.1 rule 1 / 3.18).
            return Content(text: text("SecutgStrangerAsk"), buttons: [
                Button(title: text("SecutgStrangerCheck"), action: .check),
                Button(title: text("SecutgStrangerSkip"), action: .skip),
            ])
        case .checking:
            return Content(text: text("SecutgStrangerChecking"), buttons: [])
        case let .result(textKey, commonChats):
            // Which of the 3.23.4 table's four sentences this is was decided in SecutgCore, not here:
            // five clients rebuilding one table is five chances to word one situation five ways. This
            // end only looks the key up and fills `{count}` — which the two `…NoGroups` sentences do
            // not even contain, that being why they are separate strings rather than "0 groups".
            return Content(text: text(textKey, ["count": "\(commonChats)"]), buttons: [])
        }
    }

    public func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        let configure = {
            let node = SecutgStrangerNoticeItemNode()
            let nodeLayout = node.asyncLayout()
            let (layout, apply) = nodeLayout(self, params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(.None) })
                })
            }
        }
        if Thread.isMainThread {
            async {
                configure()
            }
        } else {
            configure()
        }
    }

    public func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? SecutgStrangerNoticeItemNode {
                let nodeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = nodeLayout(self, params)
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply(animation)
                        })
                    }
                }
            }
        }
    }
}

public final class SecutgStrangerNoticeItemNode: ListViewItemNode {
    /// One tappable row: a `HighlightTrackingButtonNode` over a `TextNode`, because the text has to be
    /// laid out off the main thread with the rest of the block.
    private final class Row {
        let button = HighlightTrackingButtonNode()
        let title = TextNode()

        init() {
            self.title.isUserInteractionEnabled = false
            self.title.displaysAsynchronously = false
        }
    }

    /// The widest shape is the question, which has two answers. Nothing can ask for more without a new
    /// state, which would be a spec change and not a layout accident.
    private static let maxButtons = 2

    private let offsetContainer: ASDisplayNode
    private let backgroundNode: ASImageNode
    private let textNode: TextNode
    private let buttons: [Row]

    private var item: SecutgStrangerNoticeItem?
    private var cachedFillColor: UInt32?

    public init() {
        self.offsetContainer = ASDisplayNode()

        self.backgroundNode = ASImageNode()
        self.backgroundNode.displaysAsynchronously = false
        self.backgroundNode.isUserInteractionEnabled = false

        self.textNode = TextNode()
        self.textNode.isUserInteractionEnabled = false
        self.textNode.displaysAsynchronously = false

        self.buttons = (0 ..< SecutgStrangerNoticeItemNode.maxButtons).map { _ in Row() }

        super.init(layerBacked: false, rotated: true)

        self.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)

        self.addSubnode(self.offsetContainer)
        self.offsetContainer.addSubnode(self.backgroundNode)
        self.offsetContainer.addSubnode(self.textNode)
        for button in self.buttons {
            self.offsetContainer.addSubnode(button.title)
            self.offsetContainer.addSubnode(button.button)
        }
        self.wantsTrailingItemSpaceUpdates = true

        for button in self.buttons {
            button.button.addTarget(self, action: #selector(self.buttonPressed(_:)), forControlEvents: .touchUpInside)
            button.button.highligthedChanged = { [weak button] highlighted in
                button?.title.alpha = highlighted ? 0.4 : 1.0
            }
        }
    }

    // The row is identified by the node that was tapped rather than by an index stashed on it, so a row
    // that the current shape does not use cannot run the action of the row that happens to share its slot.
    @objc private func buttonPressed(_ sender: AnyObject) {
        guard let item = self.item,
              let index = self.buttons.firstIndex(where: { $0.button === sender }),
              index < item.content.buttons.count else { return }
        SecutgStrangerNoticeHost.perform(item.content.buttons[index].action, context: item.context, peerId: item.peerId)
    }

    public func asyncLayout() -> (_ item: SecutgStrangerNoticeItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeTextLayout = TextNode.asyncLayout(self.textNode)
        let makeButtonLayouts = self.buttons.map { TextNode.asyncLayout($0.title) }
        let previousFillColor = self.cachedFillColor

        return { [weak self] item, params in
            let verticalItemInset: CGFloat = 8.0
            let horizontalInset: CGFloat = 10.0 + max(params.leftInset, params.rightInset)
            let contentInset: CGFloat = 14.0
            let topInset: CGFloat = 12.0
            let spacing: CGFloat = 6.0
            let buttonHeight: CGFloat = 36.0

            let colors = serviceMessageColorComponents(theme: item.presentationData.theme.theme, wallpaper: item.presentationData.theme.wallpaper)
            let primaryTextColor = colors.primaryText
            let accentColor = item.presentationData.theme.theme.list.itemAccentColor

            let cardWidth = max(1.0, params.width - horizontalInset * 2.0)
            let constrainedWidth = max(1.0, cardWidth - contentInset * 2.0)

            func makeText(_ make: (TextNodeLayoutArguments) -> (TextNodeLayout, () -> TextNode), _ string: String, font: UIFont, color: UIColor, width: CGFloat) -> (TextNodeLayout, () -> TextNode) {
                return make(TextNodeLayoutArguments(
                    attributedString: NSAttributedString(string: string, font: font, textColor: color),
                    backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end,
                    constrainedSize: CGSize(width: max(1.0, width), height: CGFloat.greatestFiniteMagnitude),
                    alignment: .center, cutout: nil, insets: UIEdgeInsets()))
            }

            var height = topInset

            let (textLayout, textApply) = makeText(makeTextLayout, item.content.text, font: Font.regular(15.0), color: primaryTextColor, width: constrainedWidth)
            let textFrame = CGRect(origin: CGPoint(x: horizontalInset + contentInset, y: height), size: textLayout.size)
            height += textLayout.size.height

            var buttonFrames: [(CGRect, CGRect)] = []
            var buttonApplies: [() -> TextNode] = []
            for (index, button) in item.content.buttons.enumerated() where index < makeButtonLayouts.count {
                let (buttonLayout, apply) = makeText(makeButtonLayouts[index], button.title, font: Font.regular(15.0), color: accentColor, width: constrainedWidth)
                height += spacing
                let rowRect = CGRect(x: horizontalInset, y: height, width: cardWidth, height: max(buttonHeight, buttonLayout.size.height + 10.0))
                let textRect = CGRect(origin: CGPoint(x: horizontalInset + floor((cardWidth - buttonLayout.size.width) / 2.0), y: height + floor((rowRect.height - buttonLayout.size.height) / 2.0)), size: buttonLayout.size)
                height += rowRect.height
                buttonFrames.append((rowRect, textRect))
                buttonApplies.append(apply)
            }

            height += topInset
            let backgroundFrame = CGRect(x: horizontalInset, y: 0.0, width: cardWidth, height: height)
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height + verticalItemInset * 2.0), insets: UIEdgeInsets())

            let fillColor = colors.fill
            let fillChanged = previousFillColor != fillColor.argb

            return (layout, { animation in
                guard let strongSelf = self else { return }
                strongSelf.item = item
                strongSelf.cachedFillColor = fillColor.argb

                strongSelf.offsetContainer.frame = CGRect(origin: CGPoint(x: 0.0, y: verticalItemInset), size: CGSize(width: params.width, height: height))

                if fillChanged || strongSelf.backgroundNode.image == nil {
                    strongSelf.backgroundNode.image = generateStretchableFilledCircleImage(radius: 12.0, color: fillColor)
                }
                animation.animator.updateFrame(layer: strongSelf.backgroundNode.layer, frame: backgroundFrame, completion: nil)

                let _ = textApply()
                strongSelf.textNode.frame = textFrame

                for (index, button) in strongSelf.buttons.enumerated() {
                    guard index < buttonFrames.count else {
                        button.title.isHidden = true
                        button.button.isHidden = true
                        continue
                    }
                    let _ = buttonApplies[index]()
                    button.title.isHidden = false
                    button.button.isHidden = false
                    button.title.frame = buttonFrames[index].1
                    button.button.frame = buttonFrames[index].0
                }
            })
        }
    }

    override public func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override public func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
    }
}
