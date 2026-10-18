import Foundation
import UIKit
import Display
import TelegramCore
import TelegramPresentationData

/// SECUTG (PLAN.md 3.46 补充，2026-10-04): a tiny modal "running the check" overlay — spinner + text + cancel —
/// shown the instant 〔安全体检〕 is tapped, before the page's two network reads (two-step verification, other
/// sessions) come back. `OverlayStatusController`'s `.loading` case has no text slot (it is a bare spinner HUD
/// used elsewhere for actions that need no explanation), so this is a dedicated minimal controller rather than
/// a change to that upstream one.
final class SecutgAuditLoadingOverlay: ViewController {
    private let theme: PresentationTheme
    private let text: String
    private let cancelled: () -> Void

    private var overlayNode: SecutgAuditLoadingOverlayNode {
        return self.displayNode as! SecutgAuditLoadingOverlayNode
    }

    init(theme: PresentationTheme, text: String, cancelled: @escaping () -> Void) {
        self.theme = theme
        self.text = text
        self.cancelled = cancelled

        super.init(navigationBarPresentationData: nil)

        self.statusBar.statusBarStyle = .Ignore
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = SecutgAuditLoadingOverlayNode(theme: self.theme, text: self.text, cancelled: { [weak self] in
            guard let self else { return }
            self.cancelled()
            self.dismiss()
        })
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.overlayNode.containerLayoutUpdated(layout, transition: transition)
    }

    override func dismiss(completion: (() -> Void)? = nil) {
        self.presentingViewController?.dismiss(animated: false, completion: completion)
    }
}

private final class SecutgAuditLoadingOverlayNode: ViewControllerTracingNode {
    private let dimView: UIView
    private let cardView: UIView
    private let activityIndicator: UIActivityIndicatorView
    private let label: UILabel
    private let cancelButton: UIButton
    private let cancelled: () -> Void

    init(theme: PresentationTheme, text: String, cancelled: @escaping () -> Void) {
        self.cancelled = cancelled

        self.dimView = UIView()
        self.dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.3)

        self.cardView = UIView()
        self.cardView.backgroundColor = theme.actionSheet.opaqueItemBackgroundColor
        self.cardView.layer.cornerRadius = 14.0
        self.cardView.clipsToBounds = true

        self.activityIndicator = UIActivityIndicatorView(style: .medium)
        self.activityIndicator.color = theme.actionSheet.primaryTextColor
        self.activityIndicator.startAnimating()

        self.label = UILabel()
        self.label.text = text
        self.label.textColor = theme.actionSheet.primaryTextColor
        self.label.font = Font.regular(15.0)
        self.label.textAlignment = .center
        self.label.numberOfLines = 0

        self.cancelButton = UIButton(type: .system)
        self.cancelButton.setTitle(SecutgL10n.string("SecutgCancel"), for: .normal)
        self.cancelButton.setTitleColor(theme.actionSheet.controlAccentColor, for: .normal)
        self.cancelButton.titleLabel?.font = Font.regular(15.0)

        super.init()

        self.view.addSubview(self.dimView)
        self.view.addSubview(self.cardView)
        self.cardView.addSubview(self.activityIndicator)
        self.cardView.addSubview(self.label)
        self.cardView.addSubview(self.cancelButton)

        self.cancelButton.addTarget(self, action: #selector(self.cancelPressed), for: .touchUpInside)
    }

    @objc private func cancelPressed() {
        self.cancelled()
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.dimView.frame = CGRect(origin: CGPoint(), size: layout.size)

        let cardWidth: CGFloat = min(260.0, layout.size.width - 64.0)
        let sideInset: CGFloat = 16.0
        let labelWidth = cardWidth - sideInset * 2.0
        let labelSize = self.label.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude))
        self.cancelButton.sizeToFit()

        let topInset: CGFloat = 22.0
        let spinnerHeight: CGFloat = 20.0
        let spinnerToLabelSpacing: CGFloat = 14.0
        let labelToButtonSpacing: CGFloat = 16.0
        let bottomInset: CGFloat = 16.0
        let cardHeight = topInset + spinnerHeight + spinnerToLabelSpacing + labelSize.height + labelToButtonSpacing + self.cancelButton.bounds.height + bottomInset

        let cardFrame = CGRect(
            origin: CGPoint(x: floor((layout.size.width - cardWidth) / 2.0), y: floor((layout.size.height - cardHeight) / 2.0)),
            size: CGSize(width: cardWidth, height: cardHeight))
        self.cardView.frame = cardFrame

        self.activityIndicator.frame = CGRect(
            origin: CGPoint(x: floor((cardWidth - spinnerHeight) / 2.0), y: topInset),
            size: CGSize(width: spinnerHeight, height: spinnerHeight))
        self.label.frame = CGRect(
            origin: CGPoint(x: sideInset, y: topInset + spinnerHeight + spinnerToLabelSpacing),
            size: CGSize(width: labelWidth, height: labelSize.height))
        self.cancelButton.frame = CGRect(
            origin: CGPoint(x: floor((cardWidth - self.cancelButton.bounds.width) / 2.0), y: self.label.frame.maxY + labelToButtonSpacing),
            size: self.cancelButton.bounds.size)
    }
}
