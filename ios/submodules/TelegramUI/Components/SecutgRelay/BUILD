load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# SECUTG: relay feature (PLAN.md 3.48) — its own, independent UI + runtime-glue component. Depends only on
# SecutgCore (pure logic) plus the ordinary chat-UI building blocks; nothing else in the secuTG tree depends on
# this component, so it cannot be the source of a dependency cycle the way a reverse edge would be.
swift_library(
    name = "SecutgRelay",
    module_name = "SecutgRelay",
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
        "//submodules/AppBundle:AppBundle",  # SECUTG-HOOK (PLAN.md 3.48.8): UIImage(bundleImageName:) for the relay guide illustration
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/SecutgCore:SecutgCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
