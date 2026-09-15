#!/usr/bin/env bash
# Cross-compile probe + libkgsl_wrap.so for Android aarch64.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NDK="${NDK:-${ANDROID_NDK_HOME:-$HOME/android-ndk-r26d}}"
API="${API:-28}"
CC="${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API}-clang"
OUT="${ROOT}/out/android"
mkdir -p "$OUT"

if [[ ! -x "$CC" ]]; then
  echo "missing NDK clang: $CC" >&2
  exit 1
fi

glslangValidator -V -Os "${ROOT}/probe/shader.vert" -o "${ROOT}/probe/vert.spv"
glslangValidator -V -Os "${ROOT}/probe/shader.frag" -o "${ROOT}/probe/frag.spv"
glslangValidator -V -Os "${ROOT}/probe/shader_fetch.frag" -o "${ROOT}/probe/fetch.spv"

python3 - "$ROOT" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
for name, arr, ln in (
    ("vert.spv", "vert_spv", "vert_spv_len"),
    ("frag.spv", "frag_spv", "frag_spv_len"),
    ("fetch.spv", "fetch_spv", "fetch_spv_len"),
):
    data = (root / "probe" / name).read_bytes()
    hx = ", ".join(f"0x{b:02x}" for b in data)
    (root / "probe" / f"{name}.h").write_text(
        f"static const unsigned char {arr}[] = {{ {hx} }};\n"
        f"static const unsigned int {ln} = {len(data)};\n")
print(
    "spirv headers ok",
    len((root / "probe" / "vert.spv").read_bytes()),
    len((root / "probe" / "frag.spv").read_bytes()),
    len((root / "probe" / "fetch.spv").read_bytes()),
)
PY

"$CC" -O2 -fPIE -pie -Wall -Wextra \
  -I"${ROOT}/probe" \
  -I"${NDK}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include" \
  -o "${OUT}/dagu-vk-probe" "${ROOT}/probe/probe.c" -lvulkan
echo "built ${OUT}/dagu-vk-probe"

"$CC" -O2 -fPIC -shared -Wall -Wextra \
  -I"${ROOT}/wrap" \
  -o "${OUT}/libkgsl_wrap.so" "${ROOT}/wrap/kgsl_wrap.c" -ldl
echo "built ${OUT}/libkgsl_wrap.so"

"$CC" -O2 -fPIE -pie -Wall -Wextra \
  -I"${ROOT}/wrap" \
  -o "${OUT}/kgsl_spy" "${ROOT}/wrap/kgsl_spy.c"
echo "built ${OUT}/kgsl_spy"

cp -f "${ROOT}/qgl_config.txt" "${ROOT}/qgl_config_force_gmem.txt" \
  "${ROOT}/adreno_icd.json" \
  "${ROOT}/scripts/run-on-device.sh" \
  "${ROOT}/scripts/run-heist-on-device.sh" \
  "$OUT/" 2>/dev/null || true
ls -l "$OUT"
