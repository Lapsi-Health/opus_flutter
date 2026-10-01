#!/usr/bin/env bash
# Builds the arm64 iOS Simulator slice of opus.xcframework and merges it into the published
# xcframework, leaving the device (ios-arm64) and x86_64 simulator binaries byte-identical.
#
# The published 3.0.1 slices are libopus 1.3.1, floating point, no custom modes, NEON on arm64,
# dynamic framework with install name @rpath/opus.framework/opus (compatibility/current 1.0.0),
# minimum iOS 13.0, and Xcode's Apple Generic versioning symbols (opusVersionString/Number).
# This script reproduces that configuration for the missing slice.
#
# Usage: build_arm64_simulator_slice.sh <path to opus_flutter_ios/ios> <work dir>
# Needs: Xcode command line tools, cmake, curl, shasum.
set -euo pipefail

IOS_DIR=$(cd "$1" && pwd)
WORK=$(mkdir -p "$2" && cd "$2" && pwd)
OPUS_VERSION=1.3.1
OPUS_SHA256=65b58e1e25b2a114157014736a3d9dfeaad8d41be1c8179866f144a2fb44ff9d
# The 1.3.1 release tarball omits opus_buildtype.cmake; it is taken from the same tag.
BUILDTYPE_URL=https://raw.githubusercontent.com/xiph/opus/v${OPUS_VERSION}/opus_buildtype.cmake
BUILDTYPE_SHA256=138fc685813506de6ec8ac948ecd2f942873cb90910e2e88e1c709737fff9ce3
MIN_IOS=13.0

XCF="$IOS_DIR/opus_flutter_ios/opus.xcframework"
DEVICE_FW="$XCF/ios-arm64/opus.framework"
X86_FW="$XCF/ios-x86_64-simulator/opus.framework"
[ -f "$DEVICE_FW/opus" ] && [ -f "$X86_FW/opus" ] || { echo "Expected the published 3.0.1 slices in $XCF" >&2; exit 1; }

cd "$WORK"
DEVICE_SHA=$(shasum -a 256 "$DEVICE_FW/opus" | cut -d' ' -f1)
xcrun lipo "$X86_FW/opus" -thin x86_64 -output x86_64_published.thin
X86_SHA=$(shasum -a 256 x86_64_published.thin | cut -d' ' -f1)

# 1. Source, checked.
curl -sSfLO "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
echo "${OPUS_SHA256}  opus-${OPUS_VERSION}.tar.gz" | shasum -a 256 -c -
rm -rf "opus-${OPUS_VERSION}" && tar xzf "opus-${OPUS_VERSION}.tar.gz"
curl -sSfL "$BUILDTYPE_URL" -o "opus-${OPUS_VERSION}/opus_buildtype.cmake"
echo "${BUILDTYPE_SHA256}  opus-${OPUS_VERSION}/opus_buildtype.cmake" | shasum -a 256 -c -
# libopus 1.3.1's CMake cannot enable NEON on Apple arm64: opus_config.cmake only treats the CPU
# as ARM when CMAKE_SYSTEM_PROCESSOR matches "arm", and opus_detect_neon/OPUS_PRESUME_NEON only
# accept "armv7-a|aarch64". No single value satisfies both. Widen the two regexes to accept
# "arm64" (build configuration only; no codec source is touched), so NEON is on like the
# published slices.
sed -i '' 's/MATCHES "(armv7-a|aarch64)"/MATCHES "(armv7-a|aarch64|arm64)"/' "opus-${OPUS_VERSION}/opus_functions.cmake"
sed -i '' 's/if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")/if(CMAKE_SYSTEM_PROCESSOR MATCHES "(aarch64|arm64)")/' "opus-${OPUS_VERSION}/opus_config.cmake"
grep -q 'aarch64|arm64)"' "opus-${OPUS_VERSION}/opus_functions.cmake" || { echo "NEON detection patch did not apply" >&2; exit 1; }
grep -q '"(aarch64|arm64)"' "opus-${OPUS_VERSION}/opus_config.cmake" || { echo "NEON presume patch did not apply" >&2; exit 1; }

# 2. Static libopus for the arm64 simulator. CMAKE_POLICY_VERSION_MINIMUM lets CMake >= 4 read
#    its cmake_minimum_required(3.1). Every codec option stays at its default (floating point).
#    OPUS_ARM_MAY_HAVE_NEON_INTR: libopus' autotools configure defines it together with
#    OPUS_ARM_PRESUME_NEON_INTR when it presumes NEON on aarch64, but 1.3.1's CMake only defines
#    the latter, and celt/arm/pitch_arm.h declares the NEON kernels only under the former.
rm -rf build-sim
cmake -S "opus-${OPUS_VERSION}" -B build-sim \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=${MIN_IOS} \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-DOPUS_ARM_MAY_HAVE_NEON_INTR"
cmake --build build-sim --config Release -j 4

# 3. Link it as the framework binary, with Xcode's Apple Generic versioning symbols.
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
cat > opus_vers.c <<'EOF'
extern const unsigned char opusVersionString[];
extern const double opusVersionNumber;
const unsigned char opusVersionString[] __attribute__((used)) = "@(#)PROGRAM:opus  PROJECT:opus-1" "\n";
const double opusVersionNumber __attribute__((used)) = (double)1.;
EOF
xcrun --sdk iphonesimulator clang -arch arm64 -isysroot "$SDK" -mios-simulator-version-min=${MIN_IOS} \
  -O2 -c opus_vers.c -o opus_vers.o
# Export exactly what the published device slice exports (the public opus_* API and the two
# versioning symbols).
nm -gU "$DEVICE_FW/opus" | awk '{print $3}' | sort > exported_symbols.txt
xcrun --sdk iphonesimulator clang -arch arm64 -isysroot "$SDK" -mios-simulator-version-min=${MIN_IOS} \
  -dynamiclib -Wl,-all_load build-sim/libopus.a opus_vers.o \
  -Wl,-exported_symbols_list,exported_symbols.txt \
  -install_name @rpath/opus.framework/opus -compatibility_version 1.0.0 -current_version 1.0.0 \
  -o opus_arm64_sim
xcrun strip -S opus_arm64_sim

# 4. Universal simulator framework (new arm64 + published x86_64), then the new xcframework.
rm -rf sim/opus.framework device out && mkdir -p sim device out
cp -R "$X86_FW" sim/opus.framework
xcrun lipo -create "$X86_FW/opus" opus_arm64_sim -output sim/opus.framework/opus
cp -R "$DEVICE_FW" device/opus.framework
xcodebuild -create-xcframework \
  -framework device/opus.framework \
  -framework sim/opus.framework \
  -output out/opus.xcframework

# 5. The published binaries must be untouched.
NEW_DEVICE_SHA=$(shasum -a 256 out/opus.xcframework/ios-arm64/opus.framework/opus | cut -d' ' -f1)
xcrun lipo out/opus.xcframework/ios-arm64_x86_64-simulator/opus.framework/opus -thin x86_64 -output x86_64_new.thin
NEW_X86_SHA=$(shasum -a 256 x86_64_new.thin | cut -d' ' -f1)
[ "$NEW_DEVICE_SHA" = "$DEVICE_SHA" ] || { echo "Device slice changed" >&2; exit 1; }
[ "$NEW_X86_SHA" = "$X86_SHA" ] || { echo "x86_64 simulator binary changed" >&2; exit 1; }
nm -gU opus_arm64_sim | awk '{print $3}' | sort | diff exported_symbols.txt - \
  || { echo "The arm64 simulator slice exports a different symbol set" >&2; exit 1; }
nm opus_arm64_sim > arm64_sim_symbols.txt
grep -q '_celt_pitch_xcorr_float_neon' arm64_sim_symbols.txt || { echo "NEON is off in the arm64 simulator slice" >&2; exit 1; }

rm -rf "$XCF" && cp -R out/opus.xcframework "$XCF"
echo "opus.xcframework rebuilt: device and x86_64 unchanged, arm64 simulator slice added."
