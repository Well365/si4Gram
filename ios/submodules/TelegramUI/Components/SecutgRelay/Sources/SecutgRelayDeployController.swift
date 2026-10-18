import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import SecutgCore

/// PLAN.md 3.48.9: 设置 → secuTG → 信息中转 → 〔如何部署属于自己的信息中转〕. Same plain-scroll-view shape as
/// `SecutgRelayGuideController` (one static page of prose plus a few copyable commands does not fit ItemListUI's
/// row model) and the same one-shot theme snapshot.
public enum SecutgRelayDeployController {
    public static func controller(context: AccountContext) -> ViewController {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        return SecutgRelayDeployViewController(presentationData: presentationData)
    }
}

private final class SecutgRelayDeployViewController: ViewController {
    private let theme: PresentationTheme
    private let sourceURL: String?

    private let scroll = UIScrollView()

    private let privacyBox = UIView()
    private let privacyTitleLabel = UILabel()
    private let privacyBodyLabel = UILabel()

    private let needsLabel = UILabel()

    private let step1Label = UILabel()
    private let step2Label = UILabel()

    private let cloudflareTitleLabel = UILabel()
    private let cloudflareValueLabel = UILabel()
    private let cloudflareCopyButton = UIButton(type: .system)

    private let awsTitleLabel = UILabel()
    private let awsValueLabel = UILabel()
    private let awsCopyButton = UIButton(type: .system)

    private let gcpTitleLabel = UILabel()
    private let gcpValueLabel = UILabel()
    private let gcpCopyButton = UIButton(type: .system)

    private let dockerTitleLabel = UILabel()
    private let dockerValueLabel = UILabel()
    private let dockerCopyButton = UIButton(type: .system)

    private let step3Label = UILabel()
    private let step4Label = UILabel()
    private let dryRunLabel = UILabel()

    private let sourceTitleLabel = UILabel()
    private let sourceValueLabel = UILabel()
    private let sourceOpenButton = UIButton(type: .system)
    private let sourceCopyButton = UIButton(type: .system)

    private let httpsTipBox = UIView()
    private let httpsTipLabel = UILabel()

    init(presentationData: PresentationData) {
        self.theme = presentationData.theme
        self.sourceURL = RelaySourceUrl.validate(SecutgConfigHolder.shared.config?.distribution?.relaySource)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData))
        self.title = SecutgL10n.string("SecutgRelayDeployTitle")
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
        func styleCommand(_ label: UILabel) {
            label.font = UIFont.monospacedSystemFont(ofSize: 14.0, weight: .regular)
            label.textColor = bodyColor
            label.numberOfLines = 0
        }
        func styleCopyButton(_ button: UIButton) {
            button.setTitle(SecutgL10n.string("SecutgCopy"), for: .normal)
            button.tintColor = accentColor
            button.contentHorizontalAlignment = .left
        }

        // PLAN.md 3.48.9: the privacy box is the very first thing on the page.
        privacyBox.backgroundColor = accentColor.withAlphaComponent(self.theme.overallDarkAppearance ? 0.18 : 0.10)
        privacyBox.layer.cornerRadius = 12.0
        privacyBox.layer.masksToBounds = true
        styleTitle(privacyTitleLabel)
        privacyTitleLabel.text = SecutgL10n.string("SecutgRelayDeployPrivacyTitle")
        styleBody(privacyBodyLabel)
        privacyBodyLabel.text = SecutgL10n.string("SecutgRelayDeployPrivacy")
        privacyBox.addSubview(privacyTitleLabel)
        privacyBox.addSubview(privacyBodyLabel)
        scroll.addSubview(privacyBox)

        styleBody(needsLabel)
        needsLabel.text = SecutgL10n.string("SecutgRelayDeployNeeds")
        scroll.addSubview(needsLabel)

        styleBody(step1Label)
        step1Label.text = SecutgL10n.string("SecutgRelayDeployStep1")
        styleBody(step2Label)
        step2Label.text = SecutgL10n.string("SecutgRelayDeployStep2")
        scroll.addSubview(step1Label)
        scroll.addSubview(step2Label)

        styleTitle(cloudflareTitleLabel)
        cloudflareTitleLabel.text = SecutgL10n.string("SecutgRelayDeployCloudflare")
        styleCommand(cloudflareValueLabel)
        cloudflareValueLabel.text = SecutgRelayDeployViewController.cloudflareCommand
        styleCopyButton(cloudflareCopyButton)
        cloudflareCopyButton.addTarget(self, action: #selector(copyCloudflareTapped), for: .touchUpInside)
        scroll.addSubview(cloudflareTitleLabel)
        scroll.addSubview(cloudflareValueLabel)
        scroll.addSubview(cloudflareCopyButton)

        styleTitle(awsTitleLabel)
        awsTitleLabel.text = SecutgL10n.string("SecutgRelayDeployAws")
        styleCommand(awsValueLabel)
        awsValueLabel.text = SecutgRelayDeployViewController.awsCommand
        styleCopyButton(awsCopyButton)
        awsCopyButton.addTarget(self, action: #selector(copyAwsTapped), for: .touchUpInside)
        scroll.addSubview(awsTitleLabel)
        scroll.addSubview(awsValueLabel)
        scroll.addSubview(awsCopyButton)

        styleTitle(gcpTitleLabel)
        gcpTitleLabel.text = SecutgL10n.string("SecutgRelayDeployGcp")
        styleCommand(gcpValueLabel)
        gcpValueLabel.text = SecutgRelayDeployViewController.gcpCommand
        styleCopyButton(gcpCopyButton)
        gcpCopyButton.addTarget(self, action: #selector(copyGcpTapped), for: .touchUpInside)
        scroll.addSubview(gcpTitleLabel)
        scroll.addSubview(gcpValueLabel)
        scroll.addSubview(gcpCopyButton)

        styleTitle(dockerTitleLabel)
        dockerTitleLabel.text = SecutgL10n.string("SecutgRelayDeployDocker")
        styleCommand(dockerValueLabel)
        dockerValueLabel.text = SecutgRelayDeployViewController.dockerCommand
        styleCopyButton(dockerCopyButton)
        dockerCopyButton.addTarget(self, action: #selector(copyDockerTapped), for: .touchUpInside)
        scroll.addSubview(dockerTitleLabel)
        scroll.addSubview(dockerValueLabel)
        scroll.addSubview(dockerCopyButton)

        styleBody(step3Label)
        step3Label.text = SecutgL10n.string("SecutgRelayDeployStep3")
        styleBody(step4Label)
        step4Label.text = SecutgL10n.string("SecutgRelayDeployStep4")
        styleBody(dryRunLabel)
        dryRunLabel.text = SecutgL10n.string("SecutgRelayDeployDryRun")
        scroll.addSubview(step3Label)
        scroll.addSubview(step4Label)
        scroll.addSubview(dryRunLabel)

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
            sourceValueLabel.text = SecutgL10n.string("SecutgRelayGuideSourcePending")
        }

        // PLAN.md 3.48.9 item 6: same https tip box style as the guide page.
        httpsTipBox.backgroundColor = accentColor.withAlphaComponent(self.theme.overallDarkAppearance ? 0.18 : 0.10)
        httpsTipBox.layer.cornerRadius = 12.0
        httpsTipBox.layer.masksToBounds = true
        httpsTipLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .medium)
        httpsTipLabel.textColor = titleColor
        httpsTipLabel.numberOfLines = 0
        httpsTipLabel.text = "ⓘ  " + SecutgL10n.string("SecutgRelayGuideNote3")
        httpsTipBox.addSubview(httpsTipLabel)
        scroll.addSubview(httpsTipBox)
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
        func placeCommand(titleLabel: UILabel, valueLabel: UILabel, copyButton: UIButton) {
            placeLabel(titleLabel, gap: 4.0)
            placeLabel(valueLabel, gap: 6.0)
            let buttonHeight: CGFloat = 30.0
            copyButton.frame = CGRect(x: inset, y: y, width: 80.0, height: buttonHeight)
            y += buttonHeight + 20.0
        }

        let boxPadding: CGFloat = 12.0
        let privacyTitleHeight = privacyTitleLabel.sizeThatFits(CGSize(width: width - boxPadding * 2.0, height: .greatestFiniteMagnitude)).height
        let privacyBodyHeight = privacyBodyLabel.sizeThatFits(CGSize(width: width - boxPadding * 2.0, height: .greatestFiniteMagnitude)).height
        let privacyBoxHeight = boxPadding * 2.0 + privacyTitleHeight + 6.0 + privacyBodyHeight
        privacyBox.frame = CGRect(x: inset, y: y, width: width, height: privacyBoxHeight)
        privacyTitleLabel.frame = CGRect(x: boxPadding, y: boxPadding, width: width - boxPadding * 2.0, height: privacyTitleHeight)
        privacyBodyLabel.frame = CGRect(x: boxPadding, y: boxPadding + privacyTitleHeight + 6.0, width: width - boxPadding * 2.0, height: privacyBodyHeight)
        y += privacyBoxHeight + 24.0

        placeLabel(needsLabel, gap: 24.0)

        placeLabel(step1Label, gap: 12.0)
        placeLabel(step2Label, gap: 20.0)

        placeCommand(titleLabel: cloudflareTitleLabel, valueLabel: cloudflareValueLabel, copyButton: cloudflareCopyButton)
        placeCommand(titleLabel: awsTitleLabel, valueLabel: awsValueLabel, copyButton: awsCopyButton)
        placeCommand(titleLabel: gcpTitleLabel, valueLabel: gcpValueLabel, copyButton: gcpCopyButton)
        placeCommand(titleLabel: dockerTitleLabel, valueLabel: dockerValueLabel, copyButton: dockerCopyButton)

        placeLabel(step3Label, gap: 12.0)
        placeLabel(step4Label, gap: 12.0)
        placeLabel(dryRunLabel, gap: 24.0)

        placeLabel(sourceTitleLabel, gap: 4.0)
        placeLabel(sourceValueLabel, gap: sourceURL != nil ? 6.0 : 24.0)
        if sourceURL != nil {
            let buttonHeight: CGFloat = 30.0
            sourceOpenButton.frame = CGRect(x: inset, y: y, width: 80.0, height: buttonHeight)
            sourceCopyButton.frame = CGRect(x: inset + 90.0, y: y, width: 80.0, height: buttonHeight)
            y += buttonHeight + 24.0
        }

        let tipHeight = httpsTipLabel.sizeThatFits(CGSize(width: width - boxPadding * 2.0, height: .greatestFiniteMagnitude)).height
        httpsTipBox.frame = CGRect(x: inset, y: y, width: width, height: tipHeight + boxPadding * 2.0)
        httpsTipLabel.frame = CGRect(x: boxPadding, y: boxPadding, width: width - boxPadding * 2.0, height: tipHeight)
        y += tipHeight + boxPadding * 2.0 + 24.0

        scroll.contentSize = CGSize(width: layout.size.width, height: y + layout.intrinsicInsets.bottom + 24.0)
    }

    private static let cloudflareCommand = "./deploy.sh cloudflare"
    private static let awsCommand = "./deploy.sh aws"
    private static let gcpCommand = "./deploy.sh gcp"
    private static let dockerCommand = "./deploy.sh docker --domain relay.example.com"

    @objc private func copyCloudflareTapped() {
        UIPasteboard.general.string = SecutgRelayDeployViewController.cloudflareCommand
        cloudflareCopyButton.setTitle(SecutgL10n.string("SecutgCopied"), for: .normal)
    }

    @objc private func copyAwsTapped() {
        UIPasteboard.general.string = SecutgRelayDeployViewController.awsCommand
        awsCopyButton.setTitle(SecutgL10n.string("SecutgCopied"), for: .normal)
    }

    @objc private func copyGcpTapped() {
        UIPasteboard.general.string = SecutgRelayDeployViewController.gcpCommand
        gcpCopyButton.setTitle(SecutgL10n.string("SecutgCopied"), for: .normal)
    }

    @objc private func copyDockerTapped() {
        UIPasteboard.general.string = SecutgRelayDeployViewController.dockerCommand
        dockerCopyButton.setTitle(SecutgL10n.string("SecutgCopied"), for: .normal)
    }

    @objc private func openSourceTapped() {
        guard let sourceURL = self.sourceURL, let url = URL(string: sourceURL) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    @objc private func copySourceTapped() {
        guard let sourceURL = self.sourceURL else { return }
        UIPasteboard.general.string = sourceURL
        sourceCopyButton.setTitle(SecutgL10n.string("SecutgCopied"), for: .normal)
    }
}
