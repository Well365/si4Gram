import Foundation
import UIKit

/// How this component's own raw UIKit modals (alerts, the image/text picker) get on screen (PLAN.md 3.37.1:
/// every secuTG modal must respect the passcode lock, the same rule `SecutgChatMenu.presentSystem` /
/// `SecutgAppLock.presentModal` already enforce for the rest of secuTG's UI).
///
/// `SecutgRelay` cannot import `SecutgChatMenu` to call `SecutgAppLock` directly: `SecutgChatMenu` is the side
/// that depends on `SecutgRelay` (its settings row and its chat lock-menu row push this component's screens),
/// and the reverse import would be exactly the dependency cycle PLAN.md 3.48.0 forbids. Instead, `SecutgChatMenu`
/// wires the real implementation into this one hook once (see its `syncLanguage(context:)`); until it does, the
/// fallback below presents directly, so this component never silently does nothing if that wiring is ever
/// missed, at the cost of not knowing about the passcode lock in that fallback case alone.
public enum SecutgRelayPresentation {
    public static var presentModal: (UIViewController, @escaping () -> UIViewController?) -> Void = { viewController, base in
        base()?.present(viewController, animated: true)
    }
}
