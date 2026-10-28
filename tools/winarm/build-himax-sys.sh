#!/usr/bin/env bash
# Cross-build the Himax HID minidriver .sys on Linux, in the mu-aloha container
# (clang 18 + lld-link targeting aarch64-windows-msvc), using the WDK/SDK
# headers+libs unpacked from NuGet under winarm/wdk/ex. No Windows/WDK install.
#
#   tools/winarm/build-himax-sys.sh
# Output: port/dagu/windows-drivers/himax-hx83121/himax-hx83121.sys (unsigned)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/port/dagu/windows-drivers/himax-hx83121/himax-hx83121.c"
OUT="$ROOT/port/dagu/windows-drivers/himax-hx83121/himax-hx83121.sys"
VER=10.0.26100.0
WDK="winarm/wdk/ex/microsoft.windows.wdk.arm64/c"
SDK="winarm/wdk/ex/microsoft.windows.sdk.cpp/c"

docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$ROOT:/work" -w /work mu-aloha:v1 \
  sh -euc '
VER='"$VER"'; WDK='"$WDK"'; SDK='"$SDK"'
inc="-nostdinc \
 -isystem $WDK/include/$VER/km/crt \
 -isystem $WDK/include/$VER/km \
 -isystem $WDK/include/$VER/shared \
 -isystem $SDK/include/$VER/ucrt \
 -isystem $SDK/include/$VER/shared"
clang -target aarch64-windows-msvc -c \
  -D_WIN64 -D_ARM64_ -DARM64 -D_KERNEL_MODE -DNTDDI_VERSION=0x0A000010 \
  -D_WINNT_WIN32=0x0A00 -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 \
  -O1 -mcmodel=small -fno-stack-protector -fshort-wchar -fms-extensions \
  -Wno-everything $inc \
  -o /tmp/himax.obj \
  port/dagu/windows-drivers/himax-hx83121/himax-hx83121.c
lld-link /OUT:/tmp/himax.sys /DLL /DRIVER /SUBSYSTEM:NATIVE \
  /ENTRY:DriverEntry /NODEFAULTLIB /Machine:ARM64 /IGNORE:4210 /OPT:REF \
  /LIBPATH:$WDK/lib/$VER/km/arm64 \
  /tmp/himax.obj ntoskrnl.lib hal.lib hidclass.lib libcntpr.lib
cp /tmp/himax.sys port/dagu/windows-drivers/himax-hx83121/himax-hx83121.sys
echo BUILT
'
ls -la "$OUT"
