import Foundation
import UIKit
import Display
import TelegramCore
import SecutgCore

/// SECUTG (PLAN.md 3.46.2 §1): the one-shot "this account's keys were deleted because it was signed out
/// elsewhere" notice. The flag it reads holds no account data (`SecutgLocalPrefs`'s app-level marker) and is
/// cleared the moment this is called, whether or not a controller is on screen to actually show it on — a
/// pending notice that fails to present (no window yet) is lost rather than shown twice later. Every presentation
/// goes through `SecutgAppLock.presentModal`, so it respects the app passcode lock like any other secuTG alert
/// (PLAN.md 3.37.1 / `SecutgAppLock`).
public enum SecutgSessionNotice {
    /// `controller` is any on-screen UIKit controller (the login flow's or the root navigation controller).
    public static func presentIfPending(over controller: UIViewController) {
        guard SecutgLocalPrefs.consumeSessionRevokedWipeNoticePending() else { return }
        let alert = UIAlertController(title: nil, message: SecutgL10n.string("SecutgSessionRevokedWiped"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgOk"), style: .default))
        SecutgAppLock.presentModal(alert, from: { [weak controller] in
            controller?.view.window?.rootViewController ?? controller
        })
    }
}
