import Foundation
import UIKit
import SwiftSignalKit

/// SECUTG (fix, 2026-10-02 真机, PLAN.md 3.37.1): nothing secuTG shows may sit above, or be usable through, the app's
/// passcode lock.
///
/// Why this is needed on iOS at all: Telegram's lock (`PasscodeEntryController`) is a `.passcode` layer *inside* the
/// window's root view controller, so everything Display-based (pushes, `.window(.root)`, the 3.37 cover, the floating
/// buttons in the chat list / chat) is already underneath it. A UIKit modal is not: `rootViewController.present(_:)`
/// puts the alert / sheet / picker / share sheet in a transition view *above* that root — above the lock. Telegram
/// only clears such modals at the moment it locks (and deliberately spares `UIActivityViewController`); anything
/// presented while already locked — the 3.40 launch reminder, the rejection alert, an incoming pairing dialog — lands
/// on top of the passcode screen and its buttons work.
///
/// So every secuTG UIKit modal goes through `presentModal` (`SecutgChatMenu.presentSystem`, `SecutgTransfer.presentSystem`):
/// while locked it waits for the unlock; when the lock comes up while one is on screen it is dismissed.
public enum SecutgAppLock {
    /// Telegram's own `AppLockContextImpl.isCurrentlyLocked`: the passcode is up, or the app is not in the foreground.
    private static var locked = false
    private static var disposable: Disposable?
    private static var pending: [() -> Void] = []
    private static let shown = NSHashTable<UIViewController>.weakObjects()

    /// AppDelegate hook, once, right after `AppLockContextImpl` is made. Main queue.
    public static func install(isCurrentlyLocked: Signal<Bool, NoError>, applicationIsActive: Signal<Bool, NoError>) {
        disposable?.dispose()
        // Until Telegram has said, assume locked: the first state arrives asynchronously, and a launch-time alert
        // must not slip in ahead of the passcode screen.
        locked = true
        disposable = (combineLatest(isCurrentlyLocked, applicationIsActive)
        |> deliverOnMainQueue).start(next: { isLocked, isActive in
            update(locked: isLocked, passcodeShown: isLocked && isActive)
        })
    }

    /// "Is the app currently locked" — callers that only decide whether to show something (not present it) ask this.
    public static var isLocked: Bool {
        return locked
    }

    /// "Run when unlocked": now if unlocked, otherwise right after the unlock (in order). Main queue.
    public static func whenUnlocked(_ action: @escaping () -> Void) {
        if locked {
            pending.append(action)
        } else {
            action()
        }
    }

    /// The one way a secuTG UIKit modal goes on screen. `base` is asked at presentation time (after any wait), so it
    /// should return a live controller — normally the anchor's window root; the topmost presented one is used.
    /// A held-back alert without actions is a progress indicator whose owner has most likely already "dismissed" it
    /// while it waited, so it is dropped rather than left on screen for good.
    public static func presentModal(_ viewController: UIViewController, from base: @escaping () -> UIViewController?) {
        let held = locked
        whenUnlocked {
            if held, let alert = viewController as? UIAlertController, alert.actions.isEmpty {
                return
            }
            guard var top = base() else { return }
            while let presented = top.presentedViewController {
                top = presented
            }
            shown.add(viewController)
            top.present(viewController, animated: true)
        }
    }

    /// `passcodeShown`: locked while the app is active — the passcode screen itself is up (not merely backgrounded,
    /// where a share sheet the user is in the middle of must survive an app switch).
    static func update(locked isLocked: Bool, passcodeShown: Bool) {
        locked = isLocked
        if passcodeShown {
            dismissShown()
        }
        if !isLocked {
            flush()
        }
    }

    /// Telegram dismisses the root's modals when it locks, except a share sheet; this covers that one and anything
    /// that slipped in between.
    private static func dismissShown() {
        for viewController in shown.allObjects where viewController.presentingViewController != nil {
            viewController.dismiss(animated: false)
        }
        shown.removeAllObjects()
    }

    private static func flush() {
        while !pending.isEmpty && !locked {
            let action = pending.removeFirst()
            action()
        }
    }
}
