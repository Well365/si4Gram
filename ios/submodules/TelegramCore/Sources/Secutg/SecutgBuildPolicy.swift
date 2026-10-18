import Foundation

/// SECUTG: build-wide switches that must hold regardless of how this copy was configured.
public enum Secutg {
    /// PLAN.md 3.11: a custom build never checks for, prompts about, or installs an update.
    ///
    /// Kept here rather than in the build configuration because `is_internal_build` lives in a
    /// gitignored file: anyone rebuilding from a fresh checkout would silently get the update check
    /// back, which walks users onto the official client and away from their keys.
    public static let updatesDisabled = true

    /// PLAN.md 3.18: nothing the user types leaves the device before they press send.
    ///
    /// Telegram syncs the composer to the server as a cloud draft while it is still being edited.
    /// Encrypting that draft is not the answer — what is refused is the upload itself: even as
    /// ciphertext, the request and its timing tell the server that this person is composing a
    /// message to that person, right now. Drafts stay on the device.
    ///
    /// A constant rather than a setting, for the same reason as `updatesDisabled`: a switch that
    /// can be turned off is one that will be found turned off on somebody's machine.
    public static let cloudDraftsDisabled = true

    /// PLAN.md 3.18 rule 4: link previews are not resolved while the user is composing.
    ///
    /// To show a preview card the client asks the server to resolve what is in the composer,
    /// before the user has sent anything. This client sends only the detected URLs rather than the
    /// whole text — but the rule does not turn on how much is sent: the request and its timing
    /// already say that this person is composing a message containing that link, right now.
    ///
    /// Off globally, in every chat, not only in encrypted ones, because the rule the user set is
    /// about typing and not about which chat is being typed into. The cost is visible and accepted:
    /// no preview card appears before sending. After the message is sent the server builds one
    /// itself, so in a plain chat everyone still sees a preview on the message.
    ///
    /// A constant rather than a setting, for the same reason as `cloudDraftsDisabled`.
    public static let linkPreviewsDisabled = true
}
