#!/usr/bin/env bash
# Build and test-sign dagu-smmuwt.sys with clang-cl + lld-link and the
# in-repo ARM64 WDK (same toolchain as dagu-smmushim/build.sh).
#   ./build.sh        -> tmp/smmuwt-build/dagu-smmuwt.sys
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO"

WDK="winarm/wdk/ex"
VER="10.0.26100.0"
WDKI="$WDK/microsoft.windows.wdk.arm64/c/include/$VER"
SDKI="$WDK/microsoft.windows.sdk.cpp/c/include/$VER"
WDKL="$WDK/microsoft.windows.wdk.arm64/c/lib/$VER/km/arm64"

SRC="port/dagu/windows-drivers/dagu-smmuwt/dagu-smmuwt.c"
OUT="tmp/smmuwt-build"
mkdir -p "$OUT"

clang-cl --target=aarch64-pc-windows-msvc -c \
    /GS- /O2 /W3 \
    -Wno-invalid-token-paste -Wno-deprecated-declarations -Wno-pragma-pack \
    -Wno-visibility -Wno-microsoft-anon-tag -Wno-unused-but-set-variable \
    -D_ARM64_ -DARM64 -D_WIN64 -D_KERNEL_MODE \
    -I"$WDKI/km" -I"$WDKI/km/crt" -I"$WDKI/shared" \
    -I"$SDKI/shared" -I"$SDKI/um" -I"$SDKI/ucrt" \
    "$SRC" /Fo"$OUT/dagu-smmuwt.obj"

# /DLL: without it lld-link emits an EXE image and the loader refuses it
# with STATUS_CONFLICTING_ADDRESSES.
lld-link "$OUT/dagu-smmuwt.obj" \
    /OUT:"$OUT/dagu-smmuwt.sys" \
    /DLL /DRIVER /SUBSYSTEM:NATIVE /ENTRY:DriverEntry \
    /MACHINE:ARM64 /NODEFAULTLIB \
    /LIBPATH:"$WDKL" ntoskrnl.lib hal.lib

# ARM64 Windows only loads signed kernel images, even with testsigning on.
bash "$REPO/tools/winarm/sign-driver.sh" "$OUT/dagu-smmuwt.sys"
ls -l "$OUT/dagu-smmuwt.sys"
