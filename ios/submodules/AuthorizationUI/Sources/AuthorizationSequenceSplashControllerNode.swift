import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import TelegramCore
import SolidRoundedButtonNode

// SECUTG-HOOK (PLAN.md 3.53): Si4Gram's own six-page intro replaces Telegram's `RMIntroViewController`
// (paper-plane GL animation + `Tour.*` strings). No Telegram logo/animation is shown; each page uses a
// themed SF Symbol glyph tinted with the theme's accent colour.
private final class AuthorizationSplashPageNode: ASDisplayNode {
    private let theme: PresentationTheme
    private let iconNode: ASImageNode
    private let titleNode: ASTextNode
    private let textNode: ASTextNode

    init(theme: PresentationTheme, title: String, text: String) {
        self.theme = theme
        self.iconNode = ASImageNode()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.image = UIImage(systemName: "lock.shield")?.withRenderingMode(.alwaysTemplate)
        self.iconNode.tintColor = theme.intro.accentTextColor
        self.iconNode.contentMode = .scaleAspectFit

        self.titleNode = ASTextNode()
        self.titleNode.maximumNumberOfLines = 0
        self.titleNode.textAlignment = .center
        self.titleNode.attributedText = NSAttributedString(string: title, font: Font.bold(26.0), textColor: theme.intro.primaryTextColor)

        self.textNode = ASTextNode()
        self.textNode.maximumNumberOfLines = 0
        self.textNode.textAlignment = .center
        self.textNode.attributedText = NSAttributedString(string: text, font: Font.regular(16.0), textColor: theme.intro.primaryTextColor.withAlphaComponent(0.8))

        super.init()

        self.addSubnode(self.iconNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.textNode)
    }

    // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04): lets `refreshStrings()` update an already-built page in place.
    func updateStrings(title: String, text: String) {
        self.titleNode.attributedText = NSAttributedString(string: title, font: Font.bold(26.0), textColor: self.theme.intro.primaryTextColor)
        self.textNode.attributedText = NSAttributedString(string: text, font: Font.regular(16.0), textColor: self.theme.intro.primaryTextColor.withAlphaComponent(0.8))
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        let sideInset: CGFloat = 32.0
        let contentWidth = size.width - sideInset * 2.0

        let iconSize = CGSize(width: 64.0, height: 64.0)
        let titleSize = self.titleNode.measure(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let textSize = self.textNode.measure(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))

        let spacingIconTitle: CGFloat = 24.0
        let spacingTitleText: CGFloat = 16.0
        let totalHeight = iconSize.height + spacingIconTitle + titleSize.height + spacingTitleText + textSize.height
        var originY = floor((size.height - totalHeight) / 2.0)

        transition.updateFrame(node: self.iconNode, frame: CGRect(origin: CGPoint(x: floor((size.width - iconSize.width) / 2.0), y: originY), size: iconSize))
        originY += iconSize.height + spacingIconTitle

        transition.updateFrame(node: self.titleNode, frame: CGRect(origin: CGPoint(x: floor((size.width - titleSize.width) / 2.0), y: originY), size: titleSize))
        originY += titleSize.height + spacingTitleText

        transition.updateFrame(node: self.textNode, frame: CGRect(origin: CGPoint(x: floor((size.width - textSize.width) / 2.0), y: originY), size: textSize))
    }
}

final class AuthorizationSequenceSplashControllerNode: ASDisplayNode, UIScrollViewDelegate {
    private let theme: PresentationTheme

    private let scrollNode: ASScrollNode
    private var pageNodes: [AuthorizationSplashPageNode] = []
    private let pageControlNode: ASDisplayNode
    private let pageControl: UIPageControl

    private let startButton: SolidRoundedButtonNode

    private let alternativeLanguageButton: HighlightableButtonNode
    private var alternativeLanguageCode: String?
    var alternativeLanguagePressed: ((String) -> Void)?

    private var validLayout: ContainerViewLayout?

    init(theme: PresentationTheme, startButton: SolidRoundedButtonNode) {
        self.theme = theme
        self.startButton = startButton

        self.scrollNode = ASScrollNode()
        self.scrollNode.view.isPagingEnabled = true
        self.scrollNode.view.showsHorizontalScrollIndicator = false
        self.scrollNode.view.showsVerticalScrollIndicator = false

        self.pageControl = UIPageControl()
        self.pageControl.pageIndicatorTintColor = theme.intro.dotColor
        self.pageControl.currentPageIndicatorTintColor = theme.intro.accentTextColor
        self.pageControlNode = ASDisplayNode(viewBlock: { [pageControl = self.pageControl] in
            return pageControl
        })

        self.alternativeLanguageButton = HighlightableButtonNode()
        self.alternativeLanguageButton.titleNode.maximumNumberOfLines = 1
        self.alternativeLanguageButton.alpha = 0.0
        self.alternativeLanguageButton.isUserInteractionEnabled = false

        let titles = [
            SecutgL10n.string("SecutgIntroTitle1"),
            SecutgL10n.string("SecutgIntroTitle2"),
            SecutgL10n.string("SecutgIntroTitle3"),
            SecutgL10n.string("SecutgIntroTitle4"),
            SecutgL10n.string("SecutgIntroTitle5"),
            SecutgL10n.string("SecutgIntroTitle6")
        ]
        let texts = [
            SecutgL10n.string("SecutgIntroText1"),
            SecutgL10n.string("SecutgIntroText2"),
            SecutgL10n.string("SecutgIntroText3"),
            SecutgL10n.string("SecutgIntroText4"),
            SecutgL10n.string("SecutgIntroText5"),
            SecutgL10n.string("SecutgIntroText6")
        ]

        super.init()

        self.pageNodes = (0 ..< titles.count).map { index in
            AuthorizationSplashPageNode(theme: theme, title: titles[index], text: texts[index])
        }

        self.pageControl.numberOfPages = self.pageNodes.count
        self.pageControl.currentPage = 0

        self.setViewBlock({
            return UITracingLayerView()
        })

        self.backgroundColor = theme.list.plainBackgroundColor
        self.view.disablesInteractiveTransitionGestureRecognizer = true

        self.addSubnode(self.scrollNode)
        for pageNode in self.pageNodes {
            self.scrollNode.addSubnode(pageNode)
        }
        self.addSubnode(self.pageControlNode)
        self.addSubnode(self.startButton)
        self.addSubnode(self.alternativeLanguageButton)

        self.scrollNode.view.delegate = self

        self.alternativeLanguageButton.addTarget(self, action: #selector(self.alternativeLanguagePressedEvent), forControlEvents: .touchUpInside)
    }

    // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04): rebuilds the six pages' title/text from `SecutgL10n.string`
    // after `SecutgL10n.currentLanguageCode` changes, instead of only computing them once in `init`.
    func refreshStrings() {
        let titles = [
            SecutgL10n.string("SecutgIntroTitle1"),
            SecutgL10n.string("SecutgIntroTitle2"),
            SecutgL10n.string("SecutgIntroTitle3"),
            SecutgL10n.string("SecutgIntroTitle4"),
            SecutgL10n.string("SecutgIntroTitle5"),
            SecutgL10n.string("SecutgIntroTitle6")
        ]
        let texts = [
            SecutgL10n.string("SecutgIntroText1"),
            SecutgL10n.string("SecutgIntroText2"),
            SecutgL10n.string("SecutgIntroText3"),
            SecutgL10n.string("SecutgIntroText4"),
            SecutgL10n.string("SecutgIntroText5"),
            SecutgL10n.string("SecutgIntroText6")
        ]
        for (index, pageNode) in self.pageNodes.enumerated() {
            guard index < titles.count else { break }
            pageNode.updateStrings(title: titles[index], text: texts[index])
        }
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: 0.0, transition: .immediate)
        }
    }

    func updateAlternativeLanguage(title: String?, code: String?) {
        self.alternativeLanguageCode = code
        if let title = title, code != nil, !title.isEmpty {
            self.alternativeLanguageButton.setTitle(title, with: Font.regular(16.0), with: self.theme.intro.accentTextColor, for: [])
            self.alternativeLanguageButton.isUserInteractionEnabled = true
            UIView.animate(withDuration: 0.2) {
                self.alternativeLanguageButton.alpha = 1.0
            }
        } else {
            self.alternativeLanguageButton.isUserInteractionEnabled = false
            UIView.animate(withDuration: 0.2) {
                self.alternativeLanguageButton.alpha = 0.0
            }
        }
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: 0.0, transition: .immediate)
        }
    }

    @objc private func alternativeLanguagePressedEvent() {
        if let code = self.alternativeLanguageCode {
            self.alternativeLanguagePressed?(code)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0.0 else { return }
        let page = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        self.pageControl.currentPage = max(0, min(self.pageNodes.count - 1, page))
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = layout

        let size = layout.size
        let insets = layout.insets(options: [.statusBar])

        let buttonSideInset: CGFloat = 16.0
        let buttonWidth = size.width - buttonSideInset * 2.0
        let resolvedButtonHeight = self.startButton.updateLayout(width: buttonWidth, transition: transition)

        let alternativeLanguageSize = self.alternativeLanguageButton.measure(CGSize(width: buttonWidth, height: .greatestFiniteMagnitude))
        let alternativeLanguageSpacing: CGFloat = self.alternativeLanguageButton.isUserInteractionEnabled ? 16.0 : 0.0

        let bottomContentHeight = resolvedButtonHeight + alternativeLanguageSpacing + alternativeLanguageSize.height
        let buttonY = size.height - insets.bottom - bottomContentHeight - 16.0

        transition.updateFrame(node: self.startButton, frame: CGRect(origin: CGPoint(x: buttonSideInset, y: buttonY), size: CGSize(width: buttonWidth, height: resolvedButtonHeight)))
        transition.updateFrame(node: self.alternativeLanguageButton, frame: CGRect(origin: CGPoint(x: floor((size.width - alternativeLanguageSize.width) / 2.0), y: buttonY + resolvedButtonHeight + alternativeLanguageSpacing), size: alternativeLanguageSize))

        let pageControlHeight: CGFloat = 20.0
        let pageControlY = buttonY - 16.0 - pageControlHeight
        transition.updateFrame(node: self.pageControlNode, frame: CGRect(origin: CGPoint(x: 0.0, y: pageControlY), size: CGSize(width: size.width, height: pageControlHeight)))

        let scrollFrame = CGRect(origin: CGPoint(x: 0.0, y: insets.top), size: CGSize(width: size.width, height: pageControlY - insets.top))
        transition.updateFrame(node: self.scrollNode, frame: scrollFrame)
        self.scrollNode.view.contentSize = CGSize(width: size.width * CGFloat(self.pageNodes.count), height: scrollFrame.height)

        for (index, pageNode) in self.pageNodes.enumerated() {
            let pageFrame = CGRect(origin: CGPoint(x: CGFloat(index) * size.width, y: 0.0), size: CGSize(width: size.width, height: scrollFrame.height))
            pageNode.frame = pageFrame
            pageNode.updateLayout(size: pageFrame.size, transition: transition)
        }
    }
}
