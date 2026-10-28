#!/usr/bin/env bash
# Cross-build a self-contained HIDCLASS minidriver .sys on Linux (same
# toolchain as build-himax-sys.sh: mu-aloha container, clang 18 + lld-link,
# WDK/SDK headers+libs from tools/winarm/fetch-wdk.sh under winarm/wdk/ex).
#
#   tools/winarm/build-kmdriver.sh nanosic-803
# Builds port/dagu/windows-drivers/<name>/<name>.c -> <name>.sys (unsigned).
set -euo pipefail
NAME="${1:?usage: $0 <driver-name>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REL="port/dagu/windows-drivers/$NAME"
[ -f "$ROOT/$REL/$NAME.c" ] || { echo "no $REL/$NAME.c" >&2; exit 1; }
VER=10.0.26100.0
WDK="winarm/wdk/ex/microsoft.windows.wdk.arm64/c"
SDK="winarm/wdk/ex/microsoft.windows.sdk.cpp/c"

docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$ROOT:/work" -w /work mu-aloha:v1 \
  sh -euc '
VER='"$VER"'; WDK='"$WDK"'; SDK='"$SDK"'; REL='"$REL"'; NAME='"$NAME"'
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
  -Wall -Wno-unknown-pragmas -Wno-microsoft-anon-tag -Wno-ignored-attributes \
  -Wno-pragma-pack -Wno-unused-function -Wno-missing-braces \
  -Wno-microsoft-enum-forward-reference -Wno-nonportable-include-path \
  -Wno-unused-value -Wno-microsoft-cast -Wno-ignored-pragma-intrinsic \
  -Wno-unused-but-set-variable -Wno-macro-redefined -Wno-comment \
  $inc -o /tmp/$NAME.obj $REL/$NAME.c
lld-link /OUT:/tmp/$NAME.sys /DLL /DRIVER /SUBSYSTEM:NATIVE \
  /ENTRY:DriverEntry /NODEFAULTLIB /Machine:ARM64 /IGNORE:4210 /OPT:REF \
  /LIBPATH:$WDK/lib/$VER/km/arm64 \
  /tmp/$NAME.obj ntoskrnl.lib hal.lib hidclass.lib libcntpr.lib
cp /tmp/$NAME.sys $REL/$NAME.sys
echo BUILT
'
ls -la "$ROOT/$REL/$NAME.sys"
