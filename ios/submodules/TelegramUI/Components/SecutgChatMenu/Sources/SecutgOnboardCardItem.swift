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

/// SECUTG (PLAN.md 3.24): the encryption guide drawn at the top of an unencrypted private chat.
///
/// Two roads exist for getting a key into a 1:1 chat — automatic pairing (PLAN.md 3.7, level
/// "standard · unverified") and offline QR pairing (level "high") — and until now both lived behind the
/// lock button's menu, which you have to know about before you can find them. This is the same two
/// roads, where you see them the first time you open the chat.
///
/// Three things it deliberately is not:
///
/// - **Not a second implementation.** The shape comes from `SecutgCore.OnboardCard.evaluate` reading
///   3.7's state, and every button runs an entry out of `SecutgChatMenu`'s table by id
///   (PLAN.md 3.24.7 rule 2). Two renderers of one table cannot drift into two stories.
/// - **Not a banner.** It is a row in the message list, above the first message and below the chat-info
///   block, and it scrolls away (PLAN.md 3.24.2) — so a brand-new chat shows it beside the one message
///   there is, and a chat you have had for a year keeps it out of sight unless you scroll up.
/// - **Not a thing that talks to the network.** Opening it only expands it; automatic pairing goes
///   through a confirmation that spells out the cost before any `P1` is sent (PLAN.md 3.18 / 3.24.4).
///
/// It also never tries to find out whether the peer has secuTG installed — there is no way to check
/// that does not either ask the server or put something in the chat first (PLAN.md 3.24.1 rule 3).
public final class SecutgOnboardCardItem: ListViewItem {
    struct Road {
        let title: String
        let level: String
        let hint: String
        let action: SecutgOnboardCardHost.Action
    }

    struct Button {
        let title: String
        let isDestructive: Bool
        let action: SecutgOnboardCardHost.Action
    }

    /// Everything the node draws, resolved once here — on the main queue, where the entries are built —
    /// so `asyncLayout` never touches the language table from a background thread.
    struct Content {
        let title: String
        let body: String?
        let roads: [Road]
        let buttons: [Button]
        /// 2026-10-02 (user): one line under the title when the two roads are on show (`SecutgOnboardPickHint`).
        var pickHint: String? = nil
    }

    fileprivate let context: AccountContext
    fileprivate let peerId: PeerId
    fileprivate let presentationData: ChatPresentationData
    fileprivate let content: Content
    fileprivate let controller: () -> ViewController?

    public init(
        context: AccountContext,
        peerId: PeerId,
        peerName: String,
        form: OnboardCard.Form,
        isCompact: Bool,
        isOpened: Bool,
        presentationData: ChatPresentationData,
        controller: @escaping () -> ViewController?
    ) {
        self.context = context
        self.peerId = peerId
        self.presentationData = presentationData
        self.controller = controller
        SecutgChatMenu.syncLanguage(context: context)
        // PLAN.md 3.7 rule 8: resolved here, on the main queue with the rest of `Content`, because it reads the
        // live keyring — `asyncLayout` must never do that. nil whenever this device cannot name the holder, and
        // then the `moved` title stays exactly as it was.
        self.content = SecutgOnboardCardItem.content(
            form: form, isCompact: isCompact, isOpened: isOpened, peerName: peerName,
            holder: SecutgAccountRuntime.holdingDeviceLine(accountPeerId: context.account.peerId, chatPeerId: peerId))
    }

    static func content(form: OnboardCard.Form, isCompact: Bool, isOpened: Bool, peerName: String, holder: String?) -> Content {
        func text(_ key: String, _ arguments: [String: String] = [:]) -> String {
            return SecutgL10n.string(key, arguments)
        }

        // Collapsed: one line and a way in. Reached either because the 3.23 stranger block is using the
        // space (PLAN.md 3.24.3 rule 2) or because this chat already said "not now" once (3.24.8). The
        // second button is what makes "tap [don't show this for this chat] on the collapsed row" — the
        // other half of the 3.24.8 table — reachable at all.
        if isCompact && !isOpened {
            return Content(title: text("SecutgOnboardTitle"), body: nil, roads: [], buttons: [
                Button(title: text("SecutgOnboardStart"), isDestructive: false, action: .expand),
                Button(title: text("SecutgOnboardNever"), isDestructive: false, action: .never),
            ])
        }

        switch form {
        case .offer:
            guard isOpened else {
                return Content(title: text("SecutgOnboardTitle"), body: text("SecutgOnboardBody"), roads: [], buttons: [
                    Button(title: text("SecutgOnboardStart"), isDestructive: false, action: .expand),
                    Button(title: text("SecutgOnboardNotNow"), isDestructive: false, action: .notNow),
                ])
            }
            // PLAN.md 3.24.4: the security level is printed on the option itself, not buried in the
            // explanation, because the level is the whole difference between the two roads.
            return Content(title: text("SecutgOnboardTitle"), body: text("SecutgOnboardBody"), roads: [
                Road(title: text("SecutgOnboardAuto"), level: text("SecutgLevelStandard"),
                     hint: text("SecutgOnboardAutoHint"), action: .autoPair),
                Road(title: text("SecutgOnboardOffline"), level: text("SecutgLevelHigh"),
                     hint: text("SecutgOnboardOfflineHint"), action: .offline),
            ], buttons: [
                // A way into the guide; the card never opens it by itself (PLAN.md 3.24.4, 3.15 rule 6).
                Button(title: text("SecutgGuideTitle"), isDestructive: false, action: .guideChapter),
                Button(title: text("SecutgOnboardNotNow"), isDestructive: false, action: .notNow),
            ], pickHint: text("SecutgOnboardPickHint"))
        case .incoming:
            // The peer went first. [Accept] is the button from the 3.7.1 dialog, which pops once and then
            // leaves the invitation sitting in the chat — this is where it goes on sitting. No second
            // confirmation: answering an invitation is itself the confirming tap (PLAN.md 3.24.9).
            // SECUTG-HOOK (fix, 2026-09-27 真机): no 〔改用线下配对〕 here or in the two forms below. Each of them is v2
            // state now (a pending v2 invite / a v2 exchange in flight), where the menu hides 〔手动配对〕 — a v1 key
            // imported on top would be a second, parallel key set — so the button would run nothing.
            return Content(title: text("SecutgOnboardIncoming", ["name": peerName]), body: nil, roads: [], buttons: [
                Button(title: text("SecutgAccept"), isDestructive: false, action: .accept),
                Button(title: text("SecutgOnboardNotNow"), isDestructive: false, action: .notNow),
            ])
        case .waiting:
            return Content(title: text("SecutgPairInviteSent"), body: nil, roads: [], buttons: [
                Button(title: text("SecutgOnboardWithdraw"), isDestructive: true, action: .withdraw),
            ])
        case .stale:
            // Seven days with no answer. Same state, same buttons, gentler claim — see `OnboardCard` on why
            // the wording is all that changes, and why nothing here may clear the pairing.
            return Content(title: text("SecutgOnboardStale"), body: nil, roads: [], buttons: [
                Button(title: text("SecutgOnboardWithdraw"), isDestructive: true, action: .withdraw),
            ])
        case .moved:
            // PLAN.md 3.24.6 rule 3: never the word "failed". The pairing succeeded; it happened on another
            // device. Calling it a failure makes people retry, and retrying is what caused the race.
            //
            // PLAN.md 3.7 rule 8: and say *which* device, because this card is what is left on screen once the
            // handoff notice has been dismissed — the one place the question can still be answered in passing.
            let moved = text("SecutgOnboardMoved") + (holder.map { " " + $0 } ?? "")
            return Content(title: moved, body: nil, roads: [], buttons: [
                Button(title: text("SecutgMenuRepairHere"), isDestructive: true, action: .repairHere),
            ])
        }
    }

    public func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        let configure = {
            let node = SecutgOnboardCardItemNode()
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
            if let nodeValue = node() as? SecutgOnboardCardItemNode {
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

public final class SecutgOnboardCardItemNode: ListViewItemNode {
    /// One tappable row. A `HighlightTrackingButtonNode` over a `TextNode`, because the text has to be
    /// laid out off the main thread with the rest of the card.
    private final class Row {
        let button = HighlightTrackingButtonNode()
        let title = TextNode()
        let level = TextNode()
        let hint = TextNode()
        let background = ASImageNode()
        /// A road row and a bottom button both use `Row`, but only roads populate this: the bottom
        /// buttons already read as buttons (solid text, dedicated row of their own), a road is two
        /// lines of description sitting under a tinted background, and that tint alone turned out not
        /// to read as "tap me" — this chevron is the same disclosure-arrow convention iOS list rows
        /// already use for exactly that.
        let chevron = TextNode()

        init() {
            for node in [self.title, self.level, self.hint, self.chevron] {
                node.isUserInteractionEnabled = false
                node.displaysAsynchronously = false
            }
            self.background.displaysAsynchronously = false
            self.background.isUserInteractionEnabled = false
        }
    }

    /// Fixed pools: the widest shape of the card has two roads and three buttons, and nothing can ask for
    /// more without a new form, which would be a spec change and not a layout accident.
    private static let maxRoads = 2
    private static let maxButtons = 3

    private let offsetContainer: ASDisplayNode
    private let backgroundNode: ASImageNode
    private let titleNode: TextNode
    private let pickHintNode: TextNode
    private let bodyNode: TextNode
    private let roads: [Row]
    private let buttons: [Row]

    private var item: SecutgOnboardCardItem?
    private var cachedFillColor: UInt32?

    public init() {
        self.offsetContainer = ASDisplayNode()

        self.backgroundNode = ASImageNode()
        self.backgroundNode.displaysAsynchronously = false
        self.backgroundNode.isUserInteractionEnabled = false

        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false

        self.bodyNode = TextNode()
        self.bodyNode.isUserInteractionEnabled = false
        self.bodyNode.displaysAsynchronously = false

        self.pickHintNode = TextNode()
        self.pickHintNode.isUserInteractionEnabled = false
        self.pickHintNode.displaysAsynchronously = false

        self.roads = (0 ..< SecutgOnboardCardItemNode.maxRoads).map { _ in Row() }
        self.buttons = (0 ..< SecutgOnboardCardItemNode.maxButtons).map { _ in Row() }

        super.init(layerBacked: false, rotated: true)

        self.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)

        self.addSubnode(self.offsetContainer)
        self.offsetContainer.addSubnode(self.backgroundNode)
        self.offsetContainer.addSubnode(self.titleNode)
        self.offsetContainer.addSubnode(self.pickHintNode)
        self.offsetContainer.addSubnode(self.bodyNode)
        for road in self.roads {
            self.offsetContainer.addSubnode(road.background)
            self.offsetContainer.addSubnode(road.title)
            self.offsetContainer.addSubnode(road.level)
            self.offsetContainer.addSubnode(road.hint)
            self.offsetContainer.addSubnode(road.chevron)
            self.offsetContainer.addSubnode(road.button)
        }
        for button in self.buttons {
            self.offsetContainer.addSubnode(button.title)
            self.offsetContainer.addSubnode(button.button)
        }
        self.wantsTrailingItemSpaceUpdates = true

        for road in self.roads {
            road.button.addTarget(self, action: #selector(self.roadPressed(_:)), forControlEvents: .touchUpInside)
            // 2026-10-02 (user): a road is a button — pressed, the filled background dims and the text with it.
            road.button.highligthedChanged = { [weak road] highlighted in
                guard let road else { return }
                road.background.alpha = highlighted ? 0.45 : 1.0
                for node in [road.title, road.level, road.hint, road.chevron] {
                    node.alpha = highlighted ? 0.6 : 1.0
                }
            }
        }
        for button in self.buttons {
            button.button.addTarget(self, action: #selector(self.buttonPressed(_:)), forControlEvents: .touchUpInside)
            button.button.highligthedChanged = { [weak button] highlighted in
                button?.title.alpha = highlighted ? 0.4 : 1.0
            }
        }
    }

    // The row is identified by the node that was tapped rather than by an index stashed on it, so a row
    // that the current shape does not use cannot run the action of the row that happens to share its slot.
    @objc private func roadPressed(_ sender: AnyObject) {
        guard let item = self.item,
              let index = self.roads.firstIndex(where: { $0.button === sender }),
              index < item.content.roads.count else { return }
        self.perform(item.content.roads[index].action, item: item)
    }

    @objc private func buttonPressed(_ sender: AnyObject) {
        guard let item = self.item,
              let index = self.buttons.firstIndex(where: { $0.button === sender }),
              index < item.content.buttons.count else { return }
        self.perform(item.content.buttons[index].action, item: item)
    }

    /// Everything a tap can do goes through the one place that knows the action table; the node itself
    /// carries no business logic at all (PLAN.md 3.24.7 rule 2).
    private func perform(_ action: SecutgOnboardCardHost.Action, item: SecutgOnboardCardItem) {
        SecutgOnboardCardHost.perform(action, context: item.context, peerId: item.peerId,
                                      controller: item.controller(), sourceView: self.offsetContainer.view)
    }

    public func asyncLayout() -> (_ item: SecutgOnboardCardItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makePickHintLayout = TextNode.asyncLayout(self.pickHintNode)
        let makeBodyLayout = TextNode.asyncLayout(self.bodyNode)
        let makeRoadLayouts = self.roads.map { road in
            (TextNode.asyncLayout(road.title), TextNode.asyncLayout(road.level), TextNode.asyncLayout(road.hint), TextNode.asyncLayout(road.chevron))
        }
        let makeButtonLayouts = self.buttons.map { TextNode.asyncLayout($0.title) }
        let previousFillColor = self.cachedFillColor

        return { [weak self] item, params in
            let verticalItemInset: CGFloat = 8.0
            let horizontalInset: CGFloat = 10.0 + max(params.leftInset, params.rightInset)
            let contentInset: CGFloat = 14.0
            let topInset: CGFloat = 12.0
            let spacing: CGFloat = 6.0
            let roadSpacing: CGFloat = 8.0
            let buttonHeight: CGFloat = 36.0

            let colors = serviceMessageColorComponents(theme: item.presentationData.theme.theme, wallpaper: item.presentationData.theme.wallpaper)
            let primaryTextColor = colors.primaryText
            let secondaryTextColor = primaryTextColor.withAlphaComponent(item.presentationData.theme.theme.overallDarkAppearance ? 0.7 : 0.8)
            // SECUTG-HOOK: this card floats directly on the chat wallpaper, so anything drawn on it has to
            // come from `serviceMessageColorComponents` (which is derived from the wallpaper) rather than
            // from `theme.list`, which is tuned for opaque list rows and has no idea a wallpaper exists.
            // The two buttons used to read `theme.list.itemAccentColor` — usually a blue tuned for a white
            // settings row — and on some wallpapers that blue sits at low contrast against the card's own
            // translucent fill. `primaryTextColor` is the same color the title and the road titles already
            // use, so reusing it here is what keeps every line on this card legible on the same wallpapers.
            let destructiveColor = item.presentationData.theme.theme.list.itemDestructiveColor

            let cardWidth = max(1.0, params.width - horizontalInset * 2.0)
            let constrainedWidth = max(1.0, cardWidth - contentInset * 2.0)

            func makeText(_ make: (TextNodeLayoutArguments) -> (TextNodeLayout, () -> TextNode), _ string: String, font: UIFont, color: UIColor, alignment: NSTextAlignment, width: CGFloat) -> (TextNodeLayout, () -> TextNode) {
                return make(TextNodeLayoutArguments(
                    attributedString: NSAttributedString(string: string, font: font, textColor: color),
                    backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end,
                    constrainedSize: CGSize(width: max(1.0, width), height: CGFloat.greatestFiniteMagnitude),
                    alignment: alignment, cutout: nil, insets: UIEdgeInsets()))
            }

            var height = topInset

            let (titleLayout, titleApply) = makeText(makeTitleLayout, item.content.title, font: Font.semibold(15.0), color: primaryTextColor, alignment: .center, width: constrainedWidth)
            let titleFrame = CGRect(origin: CGPoint(x: horizontalInset + contentInset, y: height), size: titleLayout.size)
            height += titleLayout.size.height

            var pickHintFrame: CGRect?
            var pickHintApply: (() -> TextNode)?
            if let pickHint = item.content.pickHint {
                let (hintLayout, apply) = makeText(makePickHintLayout, pickHint, font: Font.regular(13.0), color: secondaryTextColor, alignment: .center, width: constrainedWidth)
                height += 2.0
                pickHintFrame = CGRect(origin: CGPoint(x: horizontalInset + floor((cardWidth - hintLayout.size.width) / 2.0), y: height), size: hintLayout.size)
                pickHintApply = apply
                height += hintLayout.size.height
            }

            var bodyFrame: CGRect?
            var bodyApply: (() -> TextNode)?
            if let body = item.content.body {
                let (bodyLayout, apply) = makeText(makeBodyLayout, body, font: Font.regular(14.0), color: secondaryTextColor, alignment: .center, width: constrainedWidth)
                height += spacing
                bodyFrame = CGRect(origin: CGPoint(x: horizontalInset + contentInset, y: height), size: bodyLayout.size)
                bodyApply = apply
                height += bodyLayout.size.height
            }

            // Roads: title on the left, its security level on the right of the same line, the explanation
            // underneath, and a disclosure chevron pinned to the trailing edge — the tinted background
            // alone did not read as tappable, and the chevron is the same convention iOS list rows already
            // use for that. It gets a fixed-width slot carved out of the road's content width so the
            // title/level/hint text never runs under it, and it is centered on the whole two-line block
            // rather than on the title line alone.
            let chevronSlotWidth: CGFloat = 20.0
            let roadTextWidth = max(1.0, constrainedWidth - chevronSlotWidth)
            var roadFrames: [(CGRect, CGRect, CGRect, CGRect, CGRect)] = []
            var roadApplies: [(() -> TextNode, () -> TextNode, () -> TextNode, () -> TextNode)] = []
            for (index, road) in item.content.roads.enumerated() where index < makeRoadLayouts.count {
                let make = makeRoadLayouts[index]
                let (levelLayout, levelApply) = makeText(make.1, road.level, font: Font.medium(12.0), color: secondaryTextColor, alignment: .right, width: roadTextWidth * 0.5)
                let titleWidth = max(1.0, roadTextWidth - levelLayout.size.width - 8.0)
                let (roadTitleLayout, roadTitleApply) = makeText(make.0, road.title, font: Font.medium(14.0), color: primaryTextColor, alignment: .natural, width: titleWidth)
                let (hintLayout, hintApply) = makeText(make.2, road.hint, font: Font.regular(12.0), color: secondaryTextColor, alignment: .natural, width: roadTextWidth)
                let (chevronLayout, chevronApply) = makeText(make.3, "›", font: Font.semibold(22.0), color: primaryTextColor, alignment: .natural, width: chevronSlotWidth)

                // the block's own padding (7 pt) sits inside this gap, so neighbouring buttons never touch
                height += roadSpacing + 6.0
                let blockTop = height
                let headerHeight = max(roadTitleLayout.size.height, levelLayout.size.height)
                let titleRect = CGRect(origin: CGPoint(x: horizontalInset + contentInset, y: blockTop + floor((headerHeight - roadTitleLayout.size.height) / 2.0)), size: roadTitleLayout.size)
                let levelRect = CGRect(origin: CGPoint(x: horizontalInset + contentInset + roadTextWidth - levelLayout.size.width, y: blockTop + floor((headerHeight - levelLayout.size.height) / 2.0)), size: levelLayout.size)
                let hintRect = CGRect(origin: CGPoint(x: horizontalInset + contentInset, y: blockTop + headerHeight + 2.0), size: hintLayout.size)
                let blockHeight = headerHeight + 2.0 + hintLayout.size.height
                // Centered on the full block (header line + hint line), not just the title's line.
                let chevronRect = CGRect(origin: CGPoint(x: horizontalInset + cardWidth - contentInset - chevronLayout.size.width, y: blockTop + floor((blockHeight - chevronLayout.size.height) / 2.0)), size: chevronLayout.size)
                let blockRect = CGRect(x: horizontalInset + contentInset - 8.0, y: blockTop - 7.0, width: constrainedWidth + 16.0, height: blockHeight + 14.0)
                height += blockHeight + 7.0

                roadFrames.append((blockRect, titleRect, levelRect, hintRect, chevronRect))
                roadApplies.append((roadTitleApply, levelApply, hintApply, chevronApply))
            }

            var buttonFrames: [(CGRect, CGRect)] = []
            var buttonApplies: [() -> TextNode] = []
            for (index, button) in item.content.buttons.enumerated() where index < makeButtonLayouts.count {
                let (buttonLayout, apply) = makeText(makeButtonLayouts[index], button.title, font: Font.medium(15.0),
                                                     color: button.isDestructive ? destructiveColor : primaryTextColor,
                                                     alignment: .center, width: constrainedWidth)
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
                    // 2026-10-02 (user): the two roads read as buttons — a filled tint, a border and rounded corners,
                    // all from the wallpaper-derived text colour so they stay legible on every wallpaper.
                    for road in strongSelf.roads {
                        road.background.image = generateStretchableFilledCircleImage(diameter: 24.0, color: primaryTextColor.withAlphaComponent(0.2),
                                                                                     strokeColor: primaryTextColor.withAlphaComponent(0.55), strokeWidth: 1.0)
                    }
                }
                animation.animator.updateFrame(layer: strongSelf.backgroundNode.layer, frame: backgroundFrame, completion: nil)

                let _ = titleApply()
                strongSelf.titleNode.frame = titleFrame

                if let pickHintFrame, let pickHintApply {
                    let _ = pickHintApply()
                    strongSelf.pickHintNode.isHidden = false
                    strongSelf.pickHintNode.frame = pickHintFrame
                } else {
                    strongSelf.pickHintNode.isHidden = true
                }

                if let bodyFrame, let bodyApply {
                    let _ = bodyApply()
                    strongSelf.bodyNode.isHidden = false
                    strongSelf.bodyNode.frame = bodyFrame
                } else {
                    strongSelf.bodyNode.isHidden = true
                }

                for (index, road) in strongSelf.roads.enumerated() {
                    guard index < roadFrames.count else {
                        road.background.isHidden = true
                        road.title.isHidden = true
                        road.level.isHidden = true
                        road.hint.isHidden = true
                        road.chevron.isHidden = true
                        road.button.isHidden = true
                        continue
                    }
                    let (blockRect, titleRect, levelRect, hintRect, chevronRect) = roadFrames[index]
                    let (titleApplyRoad, levelApply, hintApply, chevronApply) = roadApplies[index]
                    let _ = titleApplyRoad()
                    let _ = levelApply()
                    let _ = hintApply()
                    let _ = chevronApply()
                    road.background.isHidden = false
                    road.title.isHidden = false
                    road.level.isHidden = false
                    road.hint.isHidden = false
                    road.chevron.isHidden = false
                    road.button.isHidden = false
                    road.background.frame = blockRect
                    road.title.frame = titleRect
                    road.level.frame = levelRect
                    road.hint.frame = hintRect
                    road.chevron.frame = chevronRect
                    road.button.frame = blockRect
                }

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
