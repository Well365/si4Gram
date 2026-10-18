#! /bin/sh
# SECUTG: builds a static libsodium for one Apple architecture. Same shape as third-party/opus/build-opus-bazel.sh.

set -ex

ARCH="$1"
BUILD_DIR=$(echo "$(cd "$(dirname "$2")"; pwd -P)/$(basename "$2")")
SOURCE_CODE_ARCHIVE="$3"

MINIOSVERSION="13.0"
MINMACOSVERSION="11.0"

SRCDIR="${BUILD_DIR}/src"
mkdir -p "$SRCDIR"
INTERDIR="${BUILD_DIR}/built"
mkdir -p "$INTERDIR"

tar zxf "$BUILD_DIR/$SOURCE_CODE_ARCHIVE" -C "$SRCDIR"
cd "${SRCDIR}/libsodium-"*

if [ "${ARCH}" = "x86_64" ]; then
  PLATFORM="iphonesimulator"
  EXTRA_CFLAGS="-arch x86_64 -mios-simulator-version-min=${MINIOSVERSION}"
  EXTRA_CONFIG="--host=x86_64-apple-darwin"
elif [ "${ARCH}" = "sim_arm64" ]; then
  PLATFORM="iphonesimulator"
  EXTRA_CFLAGS="-arch arm64 --target=arm64-apple-ios${MINIOSVERSION}-simulator"
  EXTRA_CONFIG="--host=arm-apple-darwin20"
elif [ "${ARCH}" = "macos_arm64" ]; then
  PLATFORM="macosx"
  EXTRA_CFLAGS="-arch arm64 -mmacosx-version-min=${MINMACOSVERSION}"
  EXTRA_CONFIG="--host=arm-apple-darwin20"
else
  PLATFORM="iphoneos"
  EXTRA_CFLAGS="-arch arm64 -miphoneos-version-min=${MINIOSVERSION}"
  EXTRA_CONFIG="--host=arm-apple-darwin"
fi

SDK_PATH="$(xcrun --sdk $PLATFORM --show-sdk-path 2>/dev/null)"

./configure --disable-shared --enable-static --with-pic --disable-ssp --disable-asm ${EXTRA_CONFIG} \
  --prefix="${INTERDIR}" \
  CC="$(xcrun --sdk $PLATFORM -f clang)" \
  CFLAGS="${EXTRA_CFLAGS} -Os -fPIE -isysroot ${SDK_PATH}" \
  LDFLAGS="${EXTRA_CFLAGS} -isysroot ${SDK_PATH}"

make -j"$(sysctl -n hw.ncpu)"
make install
