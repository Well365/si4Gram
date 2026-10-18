import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import SecutgCore

/// What a row of the wipe section asked for. One type rather than five closures, so the settings screen
/// forwards a value instead of growing five near-identical hooks (PLAN.md 3.16 rules 5–10).
public enum SecutgWipeMenuAction {
    /// The red row itself.
    case wipeNow
    case setNeedsConfirmation(Bool)
    case editPhrase
    case setListensToPhrase(Bool)
    case setResetsAuthorizations(Bool)
}

/// SECUTG: the settings-page side of the emergency wipe (PLAN.md 3.16 rules 5–10, 3.22.2, 3.22.9).
///
/// The rows themselves are built by `PeerInfoSettingsItems`; everything a row does when tapped lives
/// here, so the screen file stays a list of rows and the behaviour stays in one place.
///
/// Three of the five entry points ask before they act — firing the wipe, turning the confirmation off,
/// and turning the phrase listener off — because each of those is a decision the user cannot walk back
/// afterwards. The other two just flip a preference.
public enum SecutgWipeSettings {
    private static func runtime(_ context: AccountContext) -> SecutgAccountRuntime? {
        return SecutgHookRegistry.shared.runtime(for: context.account.peerId)
    }

    // MARK: - The red row (PLAN.md 3.16, item 5)

    /// Tapping "Emergency wipe". Confirms first unless the user turned the confirmation off.
    public static func tapWipeRow(context: AccountContext, controller: ViewController) {
        SecutgChatMenu.syncLanguage(context: context)
        guard let runtime = runtime(context) else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgUnavailable"))
            return
        }
        guard runtime.wipeNeedsConfirmation else {
            SecutgWipe.run(context: context, isRemote: false)
            return
        }
        let alert = UIAlertController(
            title: SecutgL10n.string("SecutgWipeConfirmTitle"),
            // 3.22.9: the user has to be told, right here, that this reaches every device on the
            // account and how to stop it wiping them again after they log back in.
            message: SecutgL10n.string("SecutgWipeConfirmBody") + "\n\n" + SecutgL10n.string("SecutgWipePhraseAbout"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgWipeConfirmAction"), style: .destructive, handler: { _ in
            SecutgWipe.run(context: context, isRemote: false)
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    // MARK: - "Ask before wiping" (PLAN.md 3.16, item 5)

    /// Turning it **on** is instant; turning it off asks, because after that a mis-tap is final. The
    /// `onChanged` callback exists because these preferences live in the keyring, not in Telegram's
    /// preferences, so nothing else will wake the settings screen to redraw the row.
    public static func setNeedsConfirmation(context: AccountContext, controller: ViewController, value: Bool, onChanged: @escaping () -> Void) {
        SecutgChatMenu.syncLanguage(context: context)
        guard let runtime = runtime(context) else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgUnavailable"))
            onChanged()
            return
        }
        if value {
            runtime.setWipeNeedsConfirmation(true)
            onChanged()
            return
        }
        let alert = UIAlertController(
            title: SecutgL10n.string("SecutgWipeDisableConfirmTitle"),
            message: SecutgL10n.string("SecutgWipeDisableConfirmBody"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgWipeDisableConfirmAction"), style: .destructive, handler: { _ in
            runtime.setWipeNeedsConfirmation(false)
            onChanged()
        }))
        // Cancel still redraws: the switch has already animated itself over, and the row must go back
        // to telling the truth.
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel, handler: { _ in onChanged() }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    // MARK: - "Respond to the Saved Messages phrase" (PLAN.md 3.16, item 8)

    /// Same shape, and for the same reason: switching this off is the user choosing that a stolen
    /// account cannot reach this device — which also means this device is the one left holding
    /// everything when the rest are wiped. That is worth one sentence before it happens.
    public static func setListensToPhrase(context: AccountContext, controller: ViewController, value: Bool, onChanged: @escaping () -> Void) {
        SecutgChatMenu.syncLanguage(context: context)
        guard let runtime = runtime(context) else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgUnavailable"))
            onChanged()
            return
        }
        if value {
            runtime.setWipeListensToPhrase(true)
            onChanged()
            return
        }
        let alert = UIAlertController(
            title: SecutgL10n.string("SecutgWipeListenToggle"),
            message: SecutgL10n.string("SecutgWipeListenToggleOff"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgWipeDisableConfirmAction"), style: .destructive, handler: { _ in
            runtime.setWipeListensToPhrase(false)
            onChanged()
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel, handler: { _ in onChanged() }))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    // MARK: - "Also end other sessions" (PLAN.md 3.16 item 9 / 3.22.6)

    /// No confirmation either way: both states are defensible and neither destroys anything.
    public static func setResetsAuthorizations(context: AccountContext, controller: ViewController, value: Bool, onChanged: @escaping () -> Void) {
        SecutgChatMenu.syncLanguage(context: context)
        guard let runtime = runtime(context) else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgUnavailable"))
            onChanged()
            return
        }
        runtime.setWipeResetsAuthorizations(value)
        onChanged()
    }

    // MARK: - The custom phrase (PLAN.md 3.16 item 7 / 3.22.2)

    /// The field is pre-filled with the phrase that is currently set, because a phrase you cannot read
    /// back is a phrase you have lost (3.22.2: it is stored in clear for exactly this reason). Empty
    /// clears it. The built-in phrase stays armed either way, and the hint on the dialog says so —
    /// nobody should walk away thinking a custom phrase replaced it.
    public static func editCustomPhrase(context: AccountContext, controller: ViewController, onChanged: @escaping () -> Void) {
        SecutgChatMenu.syncLanguage(context: context)
        guard let runtime = runtime(context) else {
            SecutgChatMenu.toast(controller, SecutgL10n.string("SecutgUnavailable"))
            return
        }
        // Everything the user needs in order to decide, in the order they need it: what the phrase does,
        // what the built-in one is (spelled out — it is public by design, PLAN.md 3.22.2), why it is
        // public, and that a phrase of their own is added to it rather than replacing it.
        let message = [
            SecutgL10n.string("SecutgWipePhraseAbout"),
            SecutgL10n.string("SecutgWipePhraseBuiltInLabel") + "\n" + WipePhrase.builtInPhrase,
            SecutgL10n.string("SecutgWipePhraseBuiltInNote"),
            SecutgL10n.string("SecutgWipePhraseCustomLabel"),
            SecutgL10n.string("SecutgWipePhraseCustomNote"),
        ].joined(separator: "\n\n")
        let alert = UIAlertController(
            title: SecutgL10n.string("SecutgWipePhraseTitle"),
            message: message,
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = SecutgL10n.string("SecutgWipePhrasePlaceholder")
            field.text = runtime.wipeCustomPhrase ?? ""
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgSave"), style: .default, handler: { [weak alert, weak controller] _ in
            guard let controller = controller else { return }
            let raw = alert?.textFields?.first?.text ?? ""
            if let rejection = runtime.setWipeCustomPhrase(raw) {
                let key = rejection == .tooShort ? "SecutgWipePhraseTooShort" : "SecutgWipePhraseSameAsBuiltIn"
                SecutgChatMenu.toast(controller, SecutgL10n.string(key))
                return
            }
            let cleared = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            SecutgChatMenu.toast(controller, SecutgL10n.string(cleared ? "SecutgWipePhraseCleared" : "SecutgWipePhraseSaved"))
            onChanged()
        }))
        alert.addAction(UIAlertAction(title: SecutgL10n.string("SecutgCancel"), style: .cancel))
        SecutgChatMenu.presentSystem(alert, over: controller)
    }

    /// The label shown next to the phrase row: the phrase itself when one is set, otherwise a reminder
    /// that only the built-in phrase is armed.
    public static func customPhraseLabel(context: AccountContext) -> String {
        guard let phrase = runtime(context)?.wipeCustomPhrase, !phrase.isEmpty else {
            return SecutgL10n.string("SecutgWipePhraseBuiltInOnly")
        }
        // The phrase itself is not shown on the row: the settings page is over a shoulder more often
        // than the dialog is. `SecutgWipePhraseCustomSet` says one is set; the dialog shows which.
        return SecutgL10n.string("SecutgWipePhraseCustomSet")
    }

    // MARK: - Dispatch

    /// The single entry point the settings screen forwards to. `onChanged` is the screen's "redraw
    /// yourself" — every one of these preferences lives in the keyring, so no preferences signal is
    /// going to fire and rebuild the rows.
    public static func perform(_ action: SecutgWipeMenuAction, context: AccountContext, controller: ViewController, onChanged: @escaping () -> Void) {
        switch action {
        case .wipeNow:
            tapWipeRow(context: context, controller: controller)
        case let .setNeedsConfirmation(value):
            setNeedsConfirmation(context: context, controller: controller, value: value, onChanged: onChanged)
        case .editPhrase:
            editCustomPhrase(context: context, controller: controller, onChanged: onChanged)
        case let .setListensToPhrase(value):
            setListensToPhrase(context: context, controller: controller, value: value, onChanged: onChanged)
        case let .setResetsAuthorizations(value):
            setResetsAuthorizations(context: context, controller: controller, value: value, onChanged: onChanged)
        }
    }
}
