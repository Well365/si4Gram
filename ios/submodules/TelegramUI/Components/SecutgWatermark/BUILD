load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# SECUTG: the spectral watermark overlay for the conversation area (PLAN.md 3.21).
# The codec lives in //submodules/SecutgCore so that macOS shares it; this target only turns a carrier into pixels.
swift_library(
    name = "SecutgWatermark",
    module_name = "SecutgWatermark",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/SecutgCore:SecutgCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
