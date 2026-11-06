#!/usr/bin/env bash
# Build dagu-smmushim.sys (ARM64 kernel driver) with clang-cl + lld-link,
# using the in-repo ARM64 WDK/SDK under winarm/wdk. No MSVC install needed.
#
# Usage: ./build.sh            (builds to tmp/shim-build/dagu-smmushim.sys)
#        ./build.sh install    (also copies to tmp/step7-deploy/)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO"

WDK="winarm/wdk/ex"
VER="10.0.26100.0"
WDKI="$WDK/microsoft.windows.wdk.arm64/c/include/$VER"
SDKI="$WDK/microsoft.windows.sdk.cpp/c/include/$VER"
WDKL="$WDK/microsoft.windows.wdk.arm64/c/lib/$VER/km/arm64"
UCRTL="$WDK/microsoft.windows.sdk.cpp.arm64/c/ucrt/arm64"

SRC="port/dagu/windows-drivers/dagu-smmushim/dagu-smmushim.c"
OUT="tmp/shim-build"
mkdir -p "$OUT"

echo "[1/2] compile"
# /kernel rejects asynchronous SEH, and clang then deletes __try around a
# plain store. /EHa keeps the handler so a faulting mode-fill write is
# caught instead of bugchecking the system.
clang-cl --target=aarch64-pc-windows-msvc -c \
    /GS- /O2 /W3 /EHa \
    -Wno-invalid-token-paste -Wno-deprecated-declarations \
    -Wno-pragma-pack -Wno-unused-but-set-variable \
    -D_ARM64_ -DARM64 -D_WIN64 -D_KERNEL_MODE \
    -I"$WDKI/km" -I"$WDKI/km/crt" -I"$WDKI/shared" \
    -I"$SDKI/shared" -I"$SDKI/um" -I"$SDKI/ucrt" \
    "$SRC" /Fo"$OUT/dagu-smmushim.obj"

echo "[2/2] link"
lld-link "$OUT/dagu-smmushim.obj" \
    /OUT:"$OUT/dagu-smmushim.sys" \
    /DRIVER /SUBSYSTEM:NATIVE /ENTRY:DriverEntry \
    /MACHINE:ARM64 /NODEFAULTLIB \
    /LIBPATH:"$WDKL" /LIBPATH:"$UCRTL" \
    ntoskrnl.lib hal.lib bufferoverflowfastfailk.lib

ls -l "$OUT/dagu-smmushim.sys"

# ARM64 Windows enforces kernel-mode code signing. The device boots
# testsigning=on and trusts our test root CA, so an unsigned .sys silently
# fails to load (DriverEntry never runs). Always test-sign the build output;
# skipping this once already cost a full flash/brick/rescue cycle.
echo "[sign] test-sign"
bash "$REPO/tools/winarm/sign-driver.sh" "$OUT/dagu-smmushim.sys"
python3 - "$OUT/dagu-smmushim.sys" <<'PY'
import sys, pefile
pe = pefile.PE(sys.argv[1], fast_load=True)
d = pe.OPTIONAL_HEADER.DATA_DIRECTORY[4]
if d.VirtualAddress == 0 or d.Size == 0:
    print("  ERROR: no certificate table after signing", file=sys.stderr); sys.exit(1)
print(f"  cert table VA=0x{d.VirtualAddress:x} size={d.Size}")
PY

if [ "${1:-}" = "install" ]; then
    cp "$OUT/dagu-smmushim.sys" tmp/step7-deploy/dagu-smmushim.sys
    echo "copied to tmp/step7-deploy/"
fi
