import Foundation
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext

/// SECUTG: the two notices of PLAN.md 3.20.
///
/// **Saved Messages made its own key.** It is a chat with nobody, so nobody had to agree to anything and nothing was
/// asked. Said once, because the key exists only on this device: the account's other devices read ciphertext until
/// the keyring is carried over (3.14). The runtime creates the key when the account first appears — before any of
/// this exists — and hands the notice over the first time the UI asks for it, which is why "once" survives a launch
/// where nobody was looking.
///
/// **A forward was re-sent encrypted.** Text-only forwards into an encrypted chat go out as fresh messages so the
/// encrypt hook sees them, which costs the forwarded-from label and the entities. Said once per batch.
public enum SecutgForwardNotice {
    private static var installedAccounts = Set<PeerId>()
    private static weak var host: ViewController?

    /// Installs both notices for this account and remembers the controller to present them over. Safe to call on
    /// every chat appearance: the subscription is made once per account and the rest only refreshes the host.
    /// Main queue only.
    public static func install(context: AccountContext, controller: ViewController) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        host = controller

        if runtime.consumeSavedMessagesNotice() {
            SecutgChatMenu.syncLanguage(context: context)
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgSavedAutoKey"))
        }

        guard !installedAccounts.contains(context.account.peerId) else { return }
        installedAccounts.insert(context.account.peerId)
        // Never disposed on purpose: one subscription per account, alive as long as the account is, so a forward
        // started from the chat list or the share sheet is announced too, not only one started in the chat that
        // happened to be on screen. `presentSystem` walks from the host's window to whatever is on top of it.
        let _ = (runtime.forwardNotices.signal() |> deliverOnMainQueue).start(next: { notice in
            let count = notice.1
            guard count > 0, let host = host else { return }
            SecutgChatMenu.syncLanguage(context: context)
            SecutgChatMenu.toast(host, SecutgL10n.string("SecutgForwardReencrypted", ["count": "\(count)"]))
        })
    }
}
