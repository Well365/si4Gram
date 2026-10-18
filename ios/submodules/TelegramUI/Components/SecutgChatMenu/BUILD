load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# SECUTG: chat "…" menu entries (encryption switch, key setup / import / QR, identity, rekey) for iOS.
swift_library(
    name = "SecutgChatMenu",
    module_name = "SecutgChatMenu",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    # SECUTG-HOOK (PLAN.md 3.53): lets SecutgSponsorController.swift / SecutgChatMenu.swift / SecutgSettingsAboutPage.swift's
    # `#if !SECUTG_STORE_BUILD` compile the sponsor controller and its call sites out of an App Store submission build.
    ] + select({
        "//Telegram:secutgStoreBuildSetting": ["-DSECUTG_STORE_BUILD"],
        "//conditions:default": [],
    }),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/ContextUI:ContextUI",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/ItemListPeerActionItem:ItemListPeerActionItem",
        # PLAN.md 3.49: "更多…" is a pushed ItemListController page now; this is the module that supplies the
        # `ItemListController(context:state:)` convenience init. Not `SettingsUI` — that would be the Bazel
        # dependency cycle this component has always avoided (SecutgChatMenu → SecutgRelay only).
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/ChatPresentationInterfaceState:ChatPresentationInterfaceState",
        "//submodules/TelegramUI/Components/LegacyChatHeaderPanelComponent",
        "//submodules/QrCodeUI:QrCodeUI",
        "//submodules/UIKitRuntimeUtils:UIKitRuntimeUtils",
        "//submodules/LocalizedPeerData:LocalizedPeerData",
        "//submodules/SecutgBuildInfo:SecutgBuildInfo",
        "//submodules/SecutgCore:SecutgCore",
        "//submodules/TelegramUI/Components/SecutgRelay:SecutgRelay", # SECUTG-HOOK (PLAN.md 3.48): one-directional only
    ],
    visibility = [
        "//visibility:public",
    ],
)
