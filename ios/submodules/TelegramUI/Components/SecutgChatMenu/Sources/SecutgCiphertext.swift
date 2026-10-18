import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import SecutgCore

/// SECUTG: "show ciphertext" on one message (PLAN.md 3.17 rule 6).
///
/// Deliberately a menu entry and not a setting. A standing switch would turn every unreadable message into a
/// screenful of base64 — the very thing rule 1 replaced with a sentence — whereas an entry somebody has to go and
/// pick is the difference between deciding for the reader and the reader asking. It is offered on messages that
/// opened as well: carrying a message to a device that has the key, and checking whether it was altered, have
/// nothing to do with whether it opened here.
///
/// **Absent rather than disabled** when there is no envelope: `Message.secutgCiphertext` returns nil and the
/// caller appends nothing, because on an ordinary, never-encrypted message the entry would be answering a
/// question nobody asked.
///
/// A screen of its own rather than an alert, and **no QR code**: an envelope can run to 4096 characters, which no
/// alert body and no QR version can hold. This one shows the bytes in a selectable monospace block and offers the
/// clipboard, which is what the three real uses need. It shares nothing with the key-material screens of 3.14 —
/// what is on display here is what the server already has, and it must never be able to grow a path to what the
/// server does not.
public final class SecutgCiphertextController: ViewController {
    private let ciphertext: String
    private let scroll = UIScrollView()
    private let titleLabel = UILabel()
    private let textBlock = UITextView()
    private let copyButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    public init(ciphertext: String) {
        self.ciphertext = ciphertext
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = .white
        self.displayNodeDidLoad()
        self.displayNode.view.addSubview(scroll)

        titleLabel.text = SecutgL10n.string("SecutgCiphertextTitle")
        titleLabel.font = UIFont.boldSystemFont(ofSize: 20.0)
        titleLabel.textColor = .black
        titleLabel.numberOfLines = 0
        scroll.addSubview(titleLabel)

        // Selectable but not editable: the reader may want to take part of it, and nothing he types here could
        // mean anything — what is shown is the stored bytes, and this screen never writes any back.
        textBlock.text = ciphertext
        textBlock.isEditable = false
        textBlock.isSelectable = true
        textBlock.isScrollEnabled = false
        textBlock.font = UIFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
        textBlock.textColor = .black
        textBlock.backgroundColor = UIColor(white: 0.94, alpha: 1.0)
        textBlock.layer.cornerRadius = 10.0
        textBlock.layer.masksToBounds = true
        scroll.addSubview(textBlock)

        for (button, title, action) in [
            (copyButton, SecutgL10n.string("SecutgCopyCiphertext"), #selector(copyTapped)),
            (closeButton, SecutgL10n.string("SecutgClose"), #selector(closeTapped)),
        ] {
            button.setTitle(title, for: .normal)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.addTarget(self, action: action, for: .touchUpInside)
            scroll.addSubview(button)
        }
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let inset: CGFloat = 24.0
        let width = layout.size.width - inset * 2.0
        scroll.frame = CGRect(origin: CGPoint(), size: layout.size)
        var y = layout.safeInsets.top + 32.0
        func place(_ view: UIView, height: CGFloat? = nil, gap: CGFloat = 14.0) {
            let fitted = height ?? view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            view.frame = CGRect(x: inset, y: y, width: width, height: fitted)
            y += fitted + gap
        }
        place(titleLabel, gap: 12.0)
        place(textBlock, height: textBlock.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 8.0, gap: 14.0)
        place(copyButton, height: 44.0, gap: 6.0)
        place(closeButton, height: 44.0)
        scroll.contentSize = CGSize(width: layout.size.width, height: y + layout.intrinsicInsets.bottom + 24.0)
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = ciphertext
        // Plain "Copied", deliberately not the keyring screens' clipboard warning: that one says "pass it on
        // offline, never send it through Telegram", which is exactly wrong here — these bytes travelled through
        // Telegram already, and carrying them somewhere is the whole point of this screen.
        copyButton.setTitle(SecutgL10n.string("SecutgCopied"), for: .normal)
    }

    @objc private func closeTapped() {
        self.dismiss()
    }
}
