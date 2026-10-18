// GENERATED from secutg-app-name-keys.json — do not edit by hand (PLAN.md 3.51 补充 2026-10-05 用户：「三端一起做」)
// This lists the Localizable.strings keys (bundled English source) where "Telegram" names THIS app
// (permission prompts, app update / FAQ / features, passcode lock, watch/widget app name, share-sheet target, etc.).
// Keys NOT listed here are left untouched by AppNameRewrite even if their English text contains "Telegram"
// (account / network / server / contacts / support / product names such as Premium, Stars, Passport, Business, Gateway, Web, t.me).
//
// MIXED (both senses appear in the same string; needs human review, intentionally NOT auto-replaced):
//   - Premium.AboutText: While the free version of Telegram already gives its users more than any other messaging application, **Telegram Premium** pushes its capabilities even further.\n\n**Telegram Premium** is a paid option, because most Premium Features require additional expenses from Telegram to third parties such as data center providers and server manufacturers. Contributions from **Telegram Premium** users allow us to cover such costs and also help Telegram stay free for everyone.
//
// Also intentionally excluded: Settings.TipsUsername ("TelegramTips" is a concatenated bot/channel handle,
// not a whole-word occurrence of "Telegram", so whole-word replacement would never touch it anyway).
import Foundation

/// SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-05): source of truth is secutg-app-name-keys.json next to this file.
public enum AppNameKeys {
    public static let platform: String = "ios"

    /// Localizable.strings keys where "Telegram" (or one of `localizedNames`) names this app.
    public static let keys: Set<String> = [
        "AccessDenied.AgeVerificationCamera",
        "AccessDenied.CallMicrophone",
        "AccessDenied.Camera",
        "AccessDenied.CameraRestricted",
        "AccessDenied.Contacts",
        "AccessDenied.LocationAlwaysDenied",
        "AccessDenied.LocationDenied",
        "AccessDenied.LocationDisabled",
        "AccessDenied.LocationPreciseDenied",
        "AccessDenied.LocationTracking",
        "AccessDenied.LocationWeather",
        "AccessDenied.MicrophoneRestricted",
        "AccessDenied.PhotosAndVideos",
        "AccessDenied.PhotosRestricted",
        "AccessDenied.QrCamera",
        "AccessDenied.QrCode",
        "AccessDenied.SaveMedia",
        "AccessDenied.VideoCallCamera",
        "AccessDenied.VideoMessageCamera",
        "AccessDenied.VideoMessageMicrophone",
        "AccessDenied.VideoMicrophone",
        "AccessDenied.VoiceMicrophone",
        "AccessDenied.Wallpapers",
        "Application.Name",
        "ApplyLanguage.UnsufficientDataText",
        "Attachment.CameraAccessText",
        "Attachment.LimitedMediaAccessText",
        "AuthSessions.OtherDevices",
        "Cache.Indexing",
        "ChatImportActivity.OpenApp",
        "ClearCache.ClearCache",
        "ClearCache.StorageCache",
        "ClearCache.StorageServiceFiles",
        "Compatibility.SecretMediaVersionTooLow",
        "Contacts.AccessDeniedError",
        "Contacts.AccessDeniedHelpLandscape",
        "Contacts.AccessDeniedHelpPortrait",
        "Contacts.LimitedAccess.Text",
        "Conversation.FileHowToText",
        "Conversation.UnsupportedMedia",
        "Conversation.UnsupportedMediaPlaceholder",
        "DialogList.PasscodeLockHelp",
        "EnterPasscode.EnterPasscode",
        "EnterPasscode.EnterTitle",
        "EnterPasscode.TouchId",
        "Gift.Transfer.UpdateRequired.Text",
        "GroupInfo.InviteLink.Help",
        "InfoPlist.NSContactsUsageDescription",
        "InfoPlist.NSLocationAlwaysAndWhenInUseUsageDescription",
        "InfoPlist.NSLocationAlwaysUsageDescription",
        "InfoPlist.NSLocationWhenInUseUsageDescription",
        "Intents.ErrorLockedText",
        "InviteLink.CreatePrivateLinkHelp",
        "InviteLink.CreatePrivateLinkHelpChannel",
        "Login.CodeSentInternal",
        "Login.EnterCodeTelegramText",
        "Login.ErrorAppOutdated",
        "Login.PhoneGenericEmailSubject",
        "Map.HomeAndWorkInfo",
        "Media.LimitedAccessText",
        "Notifications.UploadSuccess.Text",
        "Passcode.AppLockedAlert",
        "PasscodeSettings.EncryptDataHelp",
        "Passport.UpdateRequiredError",
        "Permissions.CellularDataText.v0",
        "PowerSavingScreen.OptionAutoplayEffectsText",
        "Premium.AppIcon",
        "Premium.AppIconInfo",
        "Profile.CreateEncryptedChatOutdatedError",
        "Settings.FAQ",
        "Settings.FAQ_Intro",
        "Settings.Tips",
        "Share.AuthDescription",
        "Share.AuthTitle",
        "ShareFileTip.Text",
        "StorageManagement.DescriptionAppUsage",
        "StorageManagement.DescriptionChatUsage",
        "Story.Camera.AccessPlaceholderTitle",
        "Story.UnsupportedAction",
        "Story.UnsupportedText",
        "Tour.Text2",
        "Tour.Text3",
        "Tour.Text4",
        "Tour.Text5",
        "Tour.Text6",
        "Tour.Title1",
        "Update.AppVersion",
        "Update.Title",
        "Update.UpdateApp",
        "Watch.AppName",
        "Watch.AuthRequired",
        "Watch.Location.Access",
        "Watch.Microphone.Access",
        "WebBrowser.ClearCookies.Info",
        "WebBrowser.OpenLinksInfo",
        "WebBrowser.Telegram",
        "Widget.AuthRequired",
        "Widget.GalleryTitle",
    ]

    /// Localized spellings of the upstream app name that AppNameRewrite treats as equivalent to "Telegram".
    public static let localizedNames: [String] = [
        "Telegram",
        "تيليجرام",
        "تلگرام",
        "텔레그램",
        "Телеграм",
    ]
}

