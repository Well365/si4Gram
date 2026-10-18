# SECUTG: libsodium 1.0.20 built from the stable tarball for every Apple target, exposed to Swift as the
# `Clibsodium` module. Mirrors third-party/opus (genrule + cc_library).

headers = [
    "sodium.h",
    "sodium/core.h",
    "sodium/crypto_aead_aegis128l.h",
    "sodium/crypto_aead_aegis256.h",
    "sodium/crypto_aead_aes256gcm.h",
    "sodium/crypto_aead_chacha20poly1305.h",
    "sodium/crypto_aead_xchacha20poly1305.h",
    "sodium/crypto_auth.h",
    "sodium/crypto_auth_hmacsha256.h",
    "sodium/crypto_auth_hmacsha512.h",
    "sodium/crypto_auth_hmacsha512256.h",
    "sodium/crypto_box.h",
    "sodium/crypto_box_curve25519xchacha20poly1305.h",
    "sodium/crypto_box_curve25519xsalsa20poly1305.h",
    "sodium/crypto_core_ed25519.h",
    "sodium/crypto_core_hchacha20.h",
    "sodium/crypto_core_hsalsa20.h",
    "sodium/crypto_core_ristretto255.h",
    "sodium/crypto_core_salsa20.h",
    "sodium/crypto_core_salsa2012.h",
    "sodium/crypto_core_salsa208.h",
    "sodium/crypto_generichash.h",
    "sodium/crypto_generichash_blake2b.h",
    "sodium/crypto_hash.h",
    "sodium/crypto_hash_sha256.h",
    "sodium/crypto_hash_sha512.h",
    "sodium/crypto_kdf.h",
    "sodium/crypto_kdf_blake2b.h",
    "sodium/crypto_kdf_hkdf_sha256.h",
    "sodium/crypto_kdf_hkdf_sha512.h",
    "sodium/crypto_kx.h",
    "sodium/crypto_onetimeauth.h",
    "sodium/crypto_onetimeauth_poly1305.h",
    "sodium/crypto_pwhash.h",
    "sodium/crypto_pwhash_argon2i.h",
    "sodium/crypto_pwhash_argon2id.h",
    "sodium/crypto_pwhash_scryptsalsa208sha256.h",
    "sodium/crypto_scalarmult.h",
    "sodium/crypto_scalarmult_curve25519.h",
    "sodium/crypto_scalarmult_ed25519.h",
    "sodium/crypto_scalarmult_ristretto255.h",
    "sodium/crypto_secretbox.h",
    "sodium/crypto_secretbox_xchacha20poly1305.h",
    "sodium/crypto_secretbox_xsalsa20poly1305.h",
    "sodium/crypto_secretstream_xchacha20poly1305.h",
    "sodium/crypto_shorthash.h",
    "sodium/crypto_shorthash_siphash24.h",
    "sodium/crypto_sign.h",
    "sodium/crypto_sign_ed25519.h",
    "sodium/crypto_sign_edwards25519sha512batch.h",
    "sodium/crypto_stream.h",
    "sodium/crypto_stream_chacha20.h",
    "sodium/crypto_stream_salsa20.h",
    "sodium/crypto_stream_salsa2012.h",
    "sodium/crypto_stream_salsa208.h",
    "sodium/crypto_stream_xchacha20.h",
    "sodium/crypto_stream_xsalsa20.h",
    "sodium/crypto_verify_16.h",
    "sodium/crypto_verify_32.h",
    "sodium/crypto_verify_64.h",
    "sodium/export.h",
    "sodium/randombytes.h",
    "sodium/randombytes_internal_random.h",
    "sodium/randombytes_sysrandom.h",
    "sodium/runtime.h",
    "sodium/utils.h",
    "sodium/version.h",
]

genrule(
    name = "libsodium_build",
    srcs = [
        "build-libsodium-bazel.sh",
        "libsodium-1.0.20-stable.tar.gz",
    ],
    cmd_bash =
    """
    set -ex

    if [ "$(TARGET_CPU)" == "ios_arm64" ]; then
        BUILD_ARCH="arm64"
    elif [ "$(TARGET_CPU)" == "ios_sim_arm64" ]; then
        BUILD_ARCH="sim_arm64"
    elif [ "$(TARGET_CPU)" == "ios_x86_64" ]; then
        BUILD_ARCH="x86_64"
    elif [ "$(TARGET_CPU)" == "darwin_arm64" ]; then
        BUILD_ARCH="macos_arm64"
    else
        echo "Unsupported architecture $(TARGET_CPU)"
        exit 1
    fi

    BUILD_DIR="$(RULEDIR)/build_$${BUILD_ARCH}"
    rm -rf "$$BUILD_DIR"
    mkdir -p "$$BUILD_DIR"

    cp $(location :build-libsodium-bazel.sh) "$$BUILD_DIR/"
    cp $(location :libsodium-1.0.20-stable.tar.gz) "$$BUILD_DIR/"

    mkdir -p "$$BUILD_DIR/Public/sodium/lib"

    sh $$BUILD_DIR/build-libsodium-bazel.sh $$BUILD_ARCH "$$BUILD_DIR" libsodium-1.0.20-stable.tar.gz
    """ +
    "\n".join([
        "cp -f \"$$BUILD_DIR/built/include/{}\" \"$(location Public/include/{})\"".format(header, header) for header in headers
    ]) +
    "\n" +
    "cp -f \"$$BUILD_DIR/built/lib/libsodium.a\" \"$(location Public/lib/libsodium.a)\"",
    outs = ["Public/include/" + x for x in headers] + ["Public/lib/libsodium.a"],
    visibility = [
        "//visibility:public",
    ],
)

cc_library(
    name = "libsodium_lib",
    srcs = [":Public/lib/libsodium.a"],
)

# Swift sees this as `import Clibsodium`: objc_library with module_name generates the module map
# (same pattern as submodules/EncryptionProvider, a headers-only objc_library).
objc_library(
    name = "libsodium",
    module_name = "Clibsodium",
    enable_modules = True,
    hdrs = [":Public/include/" + x for x in headers],
    includes = ["Public/include"],
    deps = [":libsodium_lib"],
    visibility = [
        "//visibility:public",
    ],
)
