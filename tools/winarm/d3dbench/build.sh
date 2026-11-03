#!/usr/bin/env bash
# Cross-build d3dbench.exe (ARM64 Windows console app, no CRT) in the
# mu-aloha container, same clang/lld + SDK as build-kmdriver.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REL="tools/winarm/d3dbench"
VER=10.0.26100.0
SDK="winarm/wdk/ex/microsoft.windows.sdk.cpp/c"
SDKA="winarm/wdk/ex/microsoft.windows.sdk.cpp.arm64/c"
WDK="winarm/wdk/ex/microsoft.windows.wdk.arm64/c"
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$ROOT:/work" -w /work mu-aloha:v1 sh -euc '
VER='"$VER"'; SDK='"$SDK"'; SDKA='"$SDKA"'; WDK='"$WDK"'; REL='"$REL"'
clang -target aarch64-windows-msvc -c -O2 -fms-extensions -fno-stack-protector -fno-builtin \
  -nostdinc -isystem $WDK/include/$VER/km/crt -isystem $SDK/include/$VER/um \
  -isystem $SDK/include/$VER/shared -isystem $SDK/include/$VER/ucrt \
  -D_ARM64_ -DWIN32 -D_WINDOWS -DUNICODE_NOT \
  -Wno-pragma-pack -Wno-ignored-attributes -Wno-microsoft-enum-forward-reference \
  -Wno-nonportable-include-path -Wno-unknown-pragmas -Wno-microsoft-anon-tag \
  -o /tmp/d3dbench.obj $REL/d3dbench.c
lld-link /OUT:$REL/d3dbench.exe /SUBSYSTEM:CONSOLE /ENTRY:start /NODEFAULTLIB /Machine:ARM64 \
  /LIBPATH:$SDKA/um/arm64 /tmp/d3dbench.obj kernel32.lib user32.lib d3d11.lib dxgi.lib d3dcompiler.lib dxguid.lib
clang -target aarch64-windows-msvc -c -O2 -fms-extensions -fno-stack-protector -fno-builtin \
  -nostdinc -isystem $WDK/include/$VER/km/crt -isystem $SDK/include/$VER/um \
  -isystem $SDK/include/$VER/shared -isystem $SDK/include/$VER/ucrt \
  -D_ARM64_ -DWIN32 -D_WINDOWS \
  -Wno-pragma-pack -Wno-ignored-attributes -Wno-microsoft-enum-forward-reference \
  -Wno-nonportable-include-path -Wno-unknown-pragmas -Wno-microsoft-anon-tag \
  -o /tmp/glbench.obj $REL/glbench.c
lld-link /OUT:$REL/glbench.exe /SUBSYSTEM:CONSOLE /ENTRY:start /NODEFAULTLIB /Machine:ARM64 \
  /LIBPATH:$SDKA/um/arm64 /tmp/glbench.obj kernel32.lib user32.lib gdi32.lib opengl32.lib
echo BUILT
'
ls -la "$ROOT/$REL/d3dbench.exe"
