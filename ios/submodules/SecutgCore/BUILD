load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# SECUTG: shared protocol core for iOS and macOS. Pure Swift + libsodium C API.
# `//third-party/libsodium:libsodium` must provide the `Clibsodium` module (see docs/secutg/stage8-ios-status.md).
swift_library(
    name = "SecutgCore",
    module_name = "SecutgCore",
    srcs = glob([
        "Sources/SecutgCore/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//third-party/libsodium:libsodium",
    ],
    visibility = [
        "//visibility:public",
    ],
)
