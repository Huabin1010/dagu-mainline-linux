#!/usr/bin/env bash
# Cross-build the dagu GENI UART SerCx2 controller driver (.sys) on Linux, in
# the mu-aloha container (clang 18 + lld-link targeting aarch64-windows-msvc),
# using the WDK/SDK headers+libs unpacked from NuGet under winarm/wdk/ex.
#
# Unlike build-himax-sys.sh / build-kmdriver.sh this is a *KMDF* driver that
# also binds the SerCx2 serial class extension, so it links the KMDF stub
# (wdfdriverentry/wdfldr) and the SerCx2 stub, and its PE entry point is
# FxDriverEntry (the KMDF loader shim), which in turn calls our DriverEntry.
#
#   tools/winarm/build-geni-uart.sh
# Output: port/dagu/windows-drivers/dagu-geni-uart/dagu-geni-uart.sys (unsigned)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME=dagu-geni-uart
REL="port/dagu/windows-drivers/$NAME"
[ -f "$ROOT/$REL/$NAME.c" ] || { echo "no $REL/$NAME.c" >&2; exit 1; }
VER=10.0.26100.0
KMDFVER=1.33
WDK="winarm/wdk/ex/microsoft.windows.wdk.arm64/c"
SDK="winarm/wdk/ex/microsoft.windows.sdk.cpp/c"
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$ROOT:/work" -w /work mu-aloha:v1 \
  sh -euc '
VER='"$VER"'; KMDFVER='"$KMDFVER"'; WDK='"$WDK"'; SDK='"$SDK"'; REL='"$REL"'; NAME='"$NAME"'
inc="-nostdinc \
 -isystem $WDK/include/wdf/kmdf/$KMDFVER \
 -isystem $WDK/include/$VER/km/crt \
 -isystem $WDK/include/$VER/km \
 -isystem $WDK/include/$VER/km/sercx/2.0 \
 -isystem $WDK/include/$VER/shared \
 -isystem $SDK/include/$VER/ucrt \
 -isystem $SDK/include/$VER/shared"
clang -target aarch64-windows-msvc -c \
  -D_WIN64 -D_ARM64_ -DARM64 -D_KERNEL_MODE -DNTDDI_VERSION=0x0A000010 \
  -D_WINNT_WIN32=0x0A00 -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 \
  -DKMDF_VERSION_MAJOR=1 -DKMDF_VERSION_MINOR=${KMDFVER#1.} \
  -DKMDF_MINIMUM_VERSION_REQUIRED=${KMDFVER#1.} \
  -O1 -mcmodel=small -fno-stack-protector -fshort-wchar -fms-extensions \
  -Wno-everything $inc \
  -o /tmp/$NAME.obj $REL/$NAME.c
lld-link /OUT:/tmp/$NAME.sys /DLL /DRIVER /SUBSYSTEM:NATIVE \
  /ENTRY:FxDriverEntry /NODEFAULTLIB /Machine:ARM64 /IGNORE:4210 /OPT:REF \
  /LIBPATH:$WDK/lib/$VER/km/arm64 \
  /LIBPATH:$WDK/lib/$VER/km/arm64/sercx/2.0 \
  /LIBPATH:$WDK/lib/wdf/kmdf/arm64/$KMDFVER \
  /tmp/$NAME.obj wdfdriverentry.lib wdfldr.lib sercxstubs.lib \
  ntoskrnl.lib hal.lib libcntpr.lib bufferoverflowfastfailk.lib
cp /tmp/$NAME.sys $REL/$NAME.sys
echo BUILT
'
ls -la "$ROOT/$REL/$NAME.sys"
