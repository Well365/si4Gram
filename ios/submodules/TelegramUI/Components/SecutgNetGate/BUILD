load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# SECUTG: the online gate (PLAN.md 3.37). The decision lives in //submodules/SecutgCore (NetGatePolicy) so that
# macOS shares it; this target only covers the window and opens Telegram's proxy settings from the cover.
swift_library(
    name = "SecutgNetGate",
    module_name = "SecutgNetGate",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/SettingsUI:SettingsUI",
        "//submodules/TelegramUI/Components/SecutgChatMenu:SecutgChatMenu",
        "//submodules/SecutgCore:SecutgCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
