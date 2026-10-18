// SECUTG-HOOK (PLAN.md 3.53): the sponsor controller is not compiled into an App Store submission build at
// all (no symbols) — see SecutgChatMenu.swift / SecutgSettingsAboutPage.swift / PeerInfoScreenSettingsActions.swift
// for the matching `#if !SECUTG_STORE_BUILD` call sites.
#if !SECUTG_STORE_BUILD
import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import AccountContext
import TelegramPresentationData
import SecutgCore

/// SECUTG: the sponsor page (PLAN.md 3.15 rule 7). Everything comes from the built-in `sponsor` block, for the same
/// reason the distribution block does: a repackaged build must not be able to swap in its own payment codes. The QR
/// codes are drawn from the configured text with the same CoreImage generator the key QR uses, so no images are
/// bundled. Tapping an address copies it.
public final class SecutgSponsorController: ViewController {
    private let context: AccountContext
    private let presentationData: PresentationData
    private let sponsor: SponsorConfig

    private let scroll = UIScrollView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let noteLabel = UILabel()
    private var codeViews: [(UIImageView, UILabel)] = []
    private var linkButtons: [UIButton] = []
    private var addressRows: [SecutgSponsorAddressRow] = []

    public init(context: AccountContext) {
        SecutgChatMenu.syncLanguage(context: context)
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.sponsor = SecutgConfigHolder.shared.config?.sponsor ?? SponsorConfig.empty
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var theme: PresentationTheme { return presentationData.theme }

    public override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = theme.list.blocksBackgroundColor
        self.displayNodeDidLoad()
        let view = self.displayNode.view

        titleLabel.text = SecutgL10n.string("SecutgSponsorTitle")
        titleLabel.font = UIFont.boldSystemFont(ofSize: 20.0)
        titleLabel.textColor = theme.list.itemPrimaryTextColor
        titleLabel.numberOfLines = 0
        closeButton.setTitle(SecutgL10n.string("SecutgClose"), for: .normal)
        closeButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        view.addSubview(scroll)

        noteLabel.font = UIFont.systemFont(ofSize: 15.0)
        noteLabel.textColor = theme.list.itemPrimaryTextColor
        noteLabel.numberOfLines = 0
        noteLabel.text = sponsor.hasContent ? (sponsor.note ?? "") : SecutgL10n.string("SecutgSponsorEmpty")
        scroll.addSubview(noteLabel)

        for entry in sponsor.qrs {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .white
            imageView.layer.cornerRadius = 8.0
            imageView.layer.masksToBounds = true
            imageView.image = SecutgKeyQrController.render(entry.value)
            let caption = UILabel()
            caption.text = entry.label
            caption.font = UIFont.systemFont(ofSize: 14.0)
            caption.textColor = theme.list.itemSecondaryTextColor
            caption.textAlignment = .center
            caption.numberOfLines = 0
            scroll.addSubview(imageView)
            scroll.addSubview(caption)
            codeViews.append((imageView, caption))
        }

        for (index, link) in sponsor.links.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(link.label, for: .normal)
            button.setTitleColor(theme.list.itemAccentColor, for: .normal)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.tag = index
            button.addTarget(self, action: #selector(linkTapped(_:)), for: .touchUpInside)
            scroll.addSubview(button)
            linkButtons.append(button)
        }

        for (index, entry) in sponsor.addresses.enumerated() {
            let row = SecutgSponsorAddressRow(label: entry.label, value: entry.value, theme: theme)
            row.tag = index
            row.addTarget(self, action: #selector(addressTapped(_:)), for: .touchUpInside)
            scroll.addSubview(row)
            addressRows.append(row)
        }
    }

    @objc private func linkTapped(_ sender: UIButton) {
        guard sender.tag >= 0, sender.tag < sponsor.links.count else { return }
        context.sharedContext.applicationBindings.openUrl(sponsor.links[sender.tag].url)
    }

    @objc private func addressTapped(_ sender: UIControl) {
        guard sender.tag >= 0, sender.tag < sponsor.addresses.count else { return }
        UIPasteboard.general.string = sponsor.addresses[sender.tag].value
        SecutgChatMenu.toast(self, SecutgL10n.string("SecutgSponsorCopied"))
    }

    @objc private func closeTapped() {
        dismiss()
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let inset: CGFloat = 20.0
        let width = layout.size.width - inset * 2.0
        let top = layout.safeInsets.top + 20.0
        closeButton.frame = CGRect(x: layout.size.width - inset - 80.0, y: top, width: 80.0, height: 32.0)
        titleLabel.frame = CGRect(x: inset, y: top, width: width - 88.0, height: 32.0)
        let scrollTop = top + 44.0
        scroll.frame = CGRect(x: 0.0, y: scrollTop, width: layout.size.width, height: max(0.0, layout.size.height - scrollTop))

        var y: CGFloat = 8.0
        func place(_ view: UIView, height: CGFloat? = nil, gap: CGFloat = 14.0) {
            let fitted = height ?? view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            view.frame = CGRect(x: inset, y: y, width: width, height: fitted)
            y += fitted + gap
        }

        if (noteLabel.text ?? "").isEmpty {
            noteLabel.frame = CGRect(x: inset, y: y, width: width, height: 0.0)
        } else {
            place(noteLabel, gap: 18.0)
        }
        let side = min(width, 220.0)
        for (imageView, caption) in codeViews {
            imageView.frame = CGRect(x: (layout.size.width - side) / 2.0, y: y, width: side, height: side)
            y += side + 8.0
            place(caption, gap: 18.0)
        }
        for button in linkButtons {
            place(button, height: 44.0, gap: 6.0)
        }
        if !linkButtons.isEmpty { y += 8.0 }
        for row in addressRows {
            place(row, height: row.height(forWidth: width), gap: 10.0)
        }
        scroll.contentSize = CGSize(width: layout.size.width, height: y + layout.intrinsicInsets.bottom + 28.0)
    }
}

/// A copyable address: the label, the value in monospace, and the "Copy" affordance.
final class SecutgSponsorAddressRow: UIControl {
    private let labelLabel = UILabel()
    private let valueLabel = UILabel()
    private let copyLabel = UILabel()

    init(label: String, value: String, theme: PresentationTheme) {
        super.init(frame: .zero)
        backgroundColor = theme.list.itemBlocksBackgroundColor
        layer.cornerRadius = 10.0
        layer.masksToBounds = true
        labelLabel.text = label
        labelLabel.font = UIFont.boldSystemFont(ofSize: 15.0)
        labelLabel.textColor = theme.list.itemPrimaryTextColor
        labelLabel.numberOfLines = 0
        valueLabel.text = value
        valueLabel.font = UIFont(name: "Menlo", size: 12.0) ?? UIFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .regular)
        valueLabel.textColor = theme.list.itemSecondaryTextColor
        valueLabel.numberOfLines = 0
        valueLabel.lineBreakMode = .byCharWrapping
        copyLabel.text = SecutgL10n.string("SecutgSponsorCopy")
        copyLabel.font = UIFont.systemFont(ofSize: 14.0)
        copyLabel.textColor = theme.list.itemAccentColor
        copyLabel.textAlignment = .right
        for label in [labelLabel, valueLabel, copyLabel] {
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static let padding: CGFloat = 12.0
    private static let copyWidth: CGFloat = 64.0

    func height(forWidth width: CGFloat) -> CGFloat {
        let textWidth = width - SecutgSponsorAddressRow.padding * 2.0
        let labelHeight = labelLabel.sizeThatFits(CGSize(width: textWidth - SecutgSponsorAddressRow.copyWidth, height: .greatestFiniteMagnitude)).height
        let valueHeight = valueLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        return labelHeight + valueHeight + 6.0 + SecutgSponsorAddressRow.padding * 2.0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let padding = SecutgSponsorAddressRow.padding
        let textWidth = bounds.width - padding * 2.0
        let labelHeight = labelLabel.sizeThatFits(CGSize(width: textWidth - SecutgSponsorAddressRow.copyWidth, height: .greatestFiniteMagnitude)).height
        labelLabel.frame = CGRect(x: padding, y: padding, width: textWidth - SecutgSponsorAddressRow.copyWidth, height: labelHeight)
        copyLabel.frame = CGRect(x: bounds.width - padding - SecutgSponsorAddressRow.copyWidth, y: padding, width: SecutgSponsorAddressRow.copyWidth, height: labelHeight)
        let valueHeight = valueLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        valueLabel.frame = CGRect(x: padding, y: labelLabel.frame.maxY + 6.0, width: textWidth, height: valueHeight)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1.0 }
    }
}
#endif
