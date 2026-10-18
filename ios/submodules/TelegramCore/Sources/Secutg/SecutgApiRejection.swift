import Foundation
import SecutgCore

/// SECUTG (PLAN.md 3.40.3): the login screen's way out when Telegram refuses this install's API credentials
/// (`API_ID_INVALID`, `API_ID_PUBLISHED_FLOOD`, …). The login screens only know TelegramCore, the screens that
/// can change the credentials live in the app, so the app installs `handler` and the login screen asks
/// `handle` before showing its own generic error. `controller` is the screen the error belongs to.
public enum SecutgApiRejectionHook {
    public static var handler: ((_ errorCode: String, _ controller: AnyObject) -> Void)?

    /// True when the error was a credentials rejection and the app took it over (the caller then shows nothing).
    public static func handle(errorDescription: String?, controller: AnyObject) -> Bool {
        guard ApiCredentialRules.isRejection(errorDescription), let code = errorDescription, let handler = handler else { return false }
        handler(code, controller)
        return true
    }
}
