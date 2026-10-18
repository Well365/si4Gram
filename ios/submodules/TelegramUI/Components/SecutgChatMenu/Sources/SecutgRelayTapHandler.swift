import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import AccountContext
import SecutgCore
import SecutgRelay

/// SECUTG-HOOK (PLAN.md 3.48.0 hook ②): what a tap on a relay card does. Lives beside the rest of secuTG's chat
/// UI glue (not inside `SecutgRelay`) specifically so it can call `SecutgAppLock`/`SecutgChatMenu.presentSystem`
/// directly — `SecutgRelay` itself must not import this component (see its own `SecutgRelayPresentation` note).
public enum SecutgRelayTapHandler {
    public static func handle(context: AccountContext, message: Message, controller: ViewController) {
        SecutgChatMenu.syncLanguage(context: context)
        SecutgRelayCard.beginTap(context: context, message: message) { step in
            apply(step, context: context, message: message, controller: controller)
        }
    }

    private static func apply(_ step: SecutgRelayCard.TapStep, context: AccountContext, message: Message, controller: ViewController) {
        switch step {
        case let .localReady(text, imageData):
            // SECUTG-HOOK (PLAN.md 3.48.7 gap e/f): whether this is a copy that was already on disk or one a
            // fetch just saved, nothing else tells the message list this message's rendering may have changed
            // (the inline-image hook in `ChatMessageTextBubbleContentNode` and the text card line both only run
            // on layout) — without this, they would only show their resolved form after the user scrolls the
            // message out of view and back. A no-op "update" is cheap and never destructive, so redrawing on
            // every `.localReady` (not just a freshly-completed fetch) is deliberately not narrowed further.
            secutgRedrawMessage(context: context, messageId: message.id)
            if let imageData, let image = UIImage(data: imageData) {
                present(SecutgRelayImageViewerController(image: image), controller: controller)
            } else if let text {
                present(SecutgRelayTextViewerController(text: text), controller: controller)
            }
        case .fetching:
            break // no spinner in this pass — the confirm step already told the user a request is about to go out
        case .invalid:
            toast(controller, SecutgL10n.string("SecutgRelayInvalid"))
        case .receivingOff:
            toast(controller, SecutgL10n.string("SecutgRelayReceiveOff"))
        case .insecureOrLANBlocked:
            toast(controller, SecutgL10n.string("SecutgRelayCardBlocked"))
        case .gone:
            toast(controller, SecutgL10n.string("SecutgRelayGone"))
        case let .fetchFailed(reason):
            let alert = UIAlertController(title: nil, message: SecutgL10n.string("SecutgRelayUnreachable") + "\n" + reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayRetry"), style: .default, handler: { _ in
                handle(context: context, message: message, controller: controller)
            }))
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
            SecutgChatMenu.presentSystem(alert, over: controller)
        case let .needsConfirmation(host, isUnknownRelay, limitedReads, _, proceed):
            var lines: [String] = []
            if isUnknownRelay {
                lines.append(SecutgL10n.string("SecutgRelayCardUnknown", ["host": host.host]))
            }
            if limitedReads > 0 {
                lines.append(SecutgL10n.string("SecutgRelayReadConfirm", ["count": "\(limitedReads)"]))
            }
            let alert = UIAlertController(title: nil, message: lines.joined(separator: "\n"), preferredStyle: .alert)
            if isUnknownRelay {
                alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayOnce"), style: .default, handler: { _ in proceed(false) }))
                alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayTrustAndOpen"), style: .default, handler: { _ in proceed(true) }))
            } else {
                alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCardOpen"), style: .default, handler: { _ in proceed(false) }))
            }
            alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgRelayCancel"), style: .cancel))
            SecutgChatMenu.presentSystem(alert, over: controller)
        }
    }

    private static func present(_ viewController: UIViewController, controller: ViewController) {
        let nav = UINavigationController(rootViewController: viewController)
        nav.modalPresentationStyle = .fullScreen
        SecutgAppLock.presentModal(nav, from: { [weak controller] in controller?.view.window?.rootViewController })
    }

    private static func toast(_ controller: ViewController, _ text: String) {
        SecutgChatMenu.toast(controller, text)
    }
}

/// A minimal, self-contained text viewer — not Telegram's own message/text controller, so it carries no risk of
/// interacting with the ordinary chat UI it is shown over.
private final class SecutgRelayTextViewerController: UIViewController {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        self.title = "Si4Gram" // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: SecutgL10n.string("SecutgClose"), style: .plain, target: self, action: #selector(closeTapped))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        let textView = UITextView(frame: view.bounds)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.font = UIFont.systemFont(ofSize: 17)
        textView.text = text
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.addSubview(textView)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}

private final class SecutgRelayImageViewerController: UIViewController {
    private let image: UIImage

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        self.title = "Si4Gram" // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04)
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: SecutgL10n.string("SecutgClose"), style: .plain, target: self, action: #selector(closeTapped))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let imageView = UIImageView(frame: view.bounds)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        view.addSubview(imageView)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}
