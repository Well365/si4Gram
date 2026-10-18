import Foundation
import UIKit
import AsyncDisplayKit
import Display
import AppBundle
import TelegramCore
import TelegramPresentationData
import AccountContext
import SecutgCore

/// PLAN.md 3.48.8: 设置 → secuTG → 信息中转 → 〔信息中转是怎么工作的？〕. A plain scroll-view page rather than an
/// `ItemListController` (the pattern every other screen in this component uses) because its content — one
/// full-width illustration plus several blocks of prose — does not fit the list-of-rows shape ItemListUI's item
/// types are built for, and writing a custom `ListViewItem` just to host an image is more surface than this single
/// static page is worth. Theme colours are read once at construction (the same one-shot pattern
/// `SecutgCiphertextController` already uses in this codebase) rather than tracked live — a theme switch while this
/// particular static page happens to be on screen is an acceptable gap.
public enum SecutgRelayGuideController {
    public static func controller(context: AccountContext) -> ViewController {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        return SecutgRelayGuideViewController(presentationData: presentationData)
    }
}

private func secutgRelayGuideImageName(lang: SecutgL10n.Lang, isDark: Bool) -> String {
    let langPart: String
    switch lang {
    case .zhHans: langPart = "ZhHans"
    case .zhHant: langPart = "ZhHant"
    case .en: langPart = "En"
    }
    return "Secutg/RelayFlow\(langPart)\(isDark ? "Dark" : "Light")"
}

private final class SecutgRelayGuideViewController: ViewController {
    private let theme: PresentationTheme
    private let sourceURL: String?

    private let scroll = UIScrollView()
    private let imageView = UIImageView()

    private let whyTitleLabel = UILabel()
    private let whyBodyLabel = UILabel()

    private let notesTitleLabel = UILabel()
    private let note1Label = UILabel()
    private let note2Label = UILabel()

    private let selfHostTitleLabel = UILabel()
    private let selfHostBodyLabel = UILabel()

    private let sourceTitleLabel = UILabel()
    private let sourceValueLabel = UILabel()
    private let sourceOpenButton = UIButton(type: .system)
    private let sourceCopyButton = UIButton(type: .system)

    private let deployTitleLabel = UILabel()
    private let deployValueLabel = UILabel()
    private let deployCopyButton = UIButton(type: .system)

    private let httpsTipBox = UIView()
    private let httpsTipLabel = UILabel()

    init(presentationData: PresentationData) {
        self.theme = presentationData.theme
        self.sourceURL = RelaySourceUrl.validate(SecutgConfigHolder.shared.config?.distribution?.relaySource)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData))
        self.title = SecutgL10n.string("SecutgRelayGuideTitle")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.theme.list.plainBackgroundColor
        self.displayNodeDidLoad()
        self.displayNode.view.addSubview(scroll)

        let titleColor = self.theme.list.itemPrimaryTextColor
        let bodyColor = self.theme.list.itemSecondaryTextColor
        let accentColor = self.theme.list.itemAccentColor

        let image = UIImage(bundleImageName: secutgRelayGuideImageName(lang: SecutgL10n.currentLang, isDark: self.theme.overallDarkAppearance))
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = SecutgL10n.string("SecutgRelayGuideImageAlt")
        scroll.addSubview(imageView)

        func styleTitle(_ label: UILabel) {
            label.font = UIFont.boldSystemFont(ofSize: 17.0)
            label.textColor = titleColor
            label.numberOfLines = 0
        }
        func styleBody(_ label: UILabel) {
            label.font = UIFont.systemFont(ofSize: 15.0)
            label.textColor = bodyColor
            label.numberOfLines = 0
        }

        styleTitle(whyTitleLabel)
        whyTitleLabel.text = SecutgL10n.string("SecutgRelayGuideWhyTitle")
        styleBody(whyBodyLabel)
        whyBodyLabel.text = SecutgL10n.string("SecutgRelayGuideWhy")

        styleTitle(notesTitleLabel)
        notesTitleLabel.text = SecutgL10n.string("SecutgRelayGuideNotesTitle")
        styleBody(note1Label)
        note1Label.text = "·  " + SecutgL10n.string("SecutgRelayGuideNote1")
        styleBody(note2Label)
        note2Label.text = "·  " + SecutgL10n.string("SecutgRelayGuideNote2")

        styleTitle(selfHostTitleLabel)
        selfHostTitleLabel.text = SecutgL10n.string("SecutgRelayGuideSelfHostTitle")
        styleBody(selfHostBodyLabel)
        selfHostBodyLabel.text = SecutgL10n.string("SecutgRelayGuideSelfHost")

        for label in [whyTitleLabel, whyBodyLabel, notesTitleLabel, note1Label, note2Label, selfHostTitleLabel, selfHostBodyLabel] {
            scroll.addSubview(label)
        }

        // PLAN.md 3.48.8 revision: the https requirement is a highlighted tip under the self-host paragraph.
        httpsTipBox.backgroundColor = accentColor.withAlphaComponent(self.theme.overallDarkAppearance ? 0.18 : 0.10)
        httpsTipBox.layer.cornerRadius = 12.0
        httpsTipBox.layer.masksToBounds = true
        httpsTipLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .medium)
        httpsTipLabel.textColor = titleColor
        httpsTipLabel.numberOfLines = 0
        httpsTipLabel.text = "ⓘ  " + SecutgL10n.string("SecutgRelayGuideNote3")
        httpsTipBox.addSubview(httpsTipLabel)
        scroll.addSubview(httpsTipBox)

        styleTitle(sourceTitleLabel)
        sourceTitleLabel.text = SecutgL10n.string("SecutgRelayGuideSourceRow")
        styleBody(sourceValueLabel)
        scroll.addSubview(sourceTitleLabel)
        scroll.addSubview(sourceValueLabel)
        if let sourceURL = self.sourceURL {
            sourceValueLabel.text = sourceURL
            for (button, title, action) in [
                (sourceOpenButton, SecutgL10n.string("SecutgRelayGuideOpen"), #selector(openSourceTapped)),
                (sourceCopyButton, SecutgL10n.string("SecutgRelayCopy"), #selector(copySourceTapped)),
            ] {
                button.setTitle(title, for: .normal)
                button.tintColor = accentColor
                button.contentHorizontalAlignment = .left
                button.addTarget(self, action: action, for: .touchUpInside)
                scroll.addSubview(button)
            }
        } else {
            // PLAN.md 3.48.8: absent source address → plain, not-tappable placeholder text.
            sourceValueLabel.text = SecutgL10n.string("SecutgRelayGuideSourcePending")
        }

        styleTitle(deployTitleLabel)
        deployTitleLabel.text = SecutgL10n.string("SecutgRelayGuideDeployRow")
        deployValueLabel.font = UIFont.monospacedSystemFont(ofSize: 14.0, weight: .regular)
        deployValueLabel.textColor = bodyColor
        deployValueLabel.numberOfLines = 0
        deployValueLabel.text = SecutgRelayGuideViewController.deployCommand
        scroll.addSubview(deployTitleLabel)
        scroll.addSubview(deployValueLabel)
        deployCopyButton.setTitle(SecutgL10n.string("SecutgRelayCopy"), for: .normal)
        deployCopyButton.tintColor = accentColor
        deployCopyButton.contentHorizontalAlignment = .left
        deployCopyButton.addTarget(self, action: #selector(copyDeployTapped), for: .touchUpInside)
        scroll.addSubview(deployCopyButton)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let inset: CGFloat = 20.0
        let width = layout.size.width - inset * 2.0
        scroll.frame = CGRect(origin: CGPoint(), size: layout.size)
        var y = layout.safeInsets.top + 8.0

        func place(_ view: UIView, height: CGFloat, gap: CGFloat) {
            view.frame = CGRect(x: inset, y: y, width: width, height: max(0.0, height))
            y += max(0.0, height) + gap
        }
        func placeLabel(_ label: UILabel, gap: CGFloat = 8.0) {
            let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            place(label, height: height, gap: gap)
        }

        if let image = imageView.image, image.size.width > 0 {
            let height = layout.size.width * image.size.height / image.size.width
            imageView.frame = CGRect(x: 0.0, y: y, width: layout.size.width, height: height)
            y += height + 24.0
        }

        placeLabel(whyTitleLabel, gap: 6.0)
        placeLabel(whyBodyLabel, gap: 24.0)

        placeLabel(notesTitleLabel, gap: 6.0)
        placeLabel(note1Label, gap: 4.0)
        placeLabel(note2Label, gap: 24.0)

        placeLabel(selfHostTitleLabel, gap: 6.0)
        placeLabel(selfHostBodyLabel, gap: 12.0)
        let tipPadding: CGFloat = 12.0
        let tipHeight = httpsTipLabel.sizeThatFits(CGSize(width: width - tipPadding * 2.0, height: .greatestFiniteMagnitude)).height
        httpsTipBox.frame = CGRect(x: inset, y: y, width: width, height: tipHeight + tipPadding * 2.0)
        httpsTipLabel.frame = CGRect(x: tipPadding, y: tipPadding, width: width - tipPadding * 2.0, height: tipHeight)
        y += tipHeight + tipPadding * 2.0 + 24.0

        placeLabel(sourceTitleLabel, gap: 4.0)
        placeLabel(sourceValueLabel, gap: sourceURL != nil ? 6.0 : 24.0)
        if sourceURL != nil {
            let buttonHeight: CGFloat = 30.0
            sourceOpenButton.frame = CGRect(x: inset, y: y, width: 80.0, height: buttonHeight)
            sourceCopyButton.frame = CGRect(x: inset + 90.0, y: y, width: 80.0, height: buttonHeight)
            y += buttonHeight + 24.0
        }

        placeLabel(deployTitleLabel, gap: 4.0)
        placeLabel(deployValueLabel, gap: 6.0)
        let deployButtonHeight: CGFloat = 30.0
        deployCopyButton.frame = CGRect(x: inset, y: y, width: 80.0, height: deployButtonHeight)
        y += deployButtonHeight + 24.0

        scroll.contentSize = CGSize(width: layout.size.width, height: y + layout.intrinsicInsets.bottom + 24.0)
    }

    private static let deployCommand = "./deploy.sh cloudflare"

    @objc private func openSourceTapped() {
        guard let sourceURL = self.sourceURL, let url = URL(string: sourceURL) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    @objc private func copySourceTapped() {
        guard let sourceURL = self.sourceURL else { return }
        UIPasteboard.general.string = sourceURL
        sourceCopyButton.setTitle(SecutgL10n.string("SecutgCopied"), for: .normal)
    }

    @objc private func copyDeployTapped() {
        UIPasteboard.general.string = SecutgRelayGuideViewController.deployCommand
        deployCopyButton.setTitle(SecutgL10n.string("SecutgCopied"), for: .normal)
    }
}
