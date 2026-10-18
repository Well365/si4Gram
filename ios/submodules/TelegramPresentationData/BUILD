load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "TelegramPresentationData",
    module_name = "TelegramPresentationData",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Postbox:Postbox",
        "//submodules/Display:Display",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/MediaResources:MediaResources",
        "//submodules/AppBundle:AppBundle",
        "//submodules/StringPluralization:StringPluralization",
        "//submodules/Sunrise:Sunrise",
        "//submodules/TinyThumbnail:TinyThumbnail",
        "//submodules/FastBlur:FastBlur",
        "//Telegram:PresentationStrings",
        "//submodules/SecutgCore:SecutgCore",  # SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-05): AppNameRewrite
    ],
    visibility = [
        "//visibility:public",
    ],
)
