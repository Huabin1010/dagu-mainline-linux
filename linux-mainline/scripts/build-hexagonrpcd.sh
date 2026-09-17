#!/usr/bin/env bash
# Cross-build linux-msm hexagonrpcd (sscrpcd reverse tunnel) for dagu aarch64.
# Source is cloned to linux-mainline/tmp/hexagonrpc (gitignored). Does not
# write out/kernel.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${HEXAGONRPC_SRC:-$ROOT/tmp/hexagonrpc}"
OUT="$ROOT/out/hexagonrpc"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
UAPI="$ROOT/tmp/hexagonrpc-uapi"
URL="${HEXAGONRPC_GIT:-https://github.com/linux-msm/hexagonrpc.git}"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need meson
need ninja
need "${CROSS}gcc"

mkdir -p "$ROOT/tmp" "$OUT"

if [[ ! -d "$SRC/.git" ]]; then
	mkdir -p "$(dirname "$SRC")"
	git clone --depth 1 "$URL" "$SRC"
fi

# dagu overlay: persist registry fopen-w / fwrite / parent-dir map
OVERLAY="$ROOT/patches/hexagonrpc"
if [[ -d "$OVERLAY" ]]; then
	cp -a "$OVERLAY/." "$SRC/"
fi

mkdir -p "$UAPI/misc"
cp -f "$ROOT/linux/include/uapi/misc/fastrpc.h" "$UAPI/misc/fastrpc.h"

cat >"$ROOT/tmp/hexagonrpc-aarch64.ini" <<EOF
[binaries]
c = '${CROSS}gcc'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-I$UAPI', '-include', 'linux/ioctl.h']
prefix = '/usr/local'
libdir = 'lib'
EOF

BUILD="$SRC/build-dagu"
if [[ ! -f "$BUILD/build.ninja" ]]; then
	meson setup "$BUILD" "$SRC" \
		--cross-file "$ROOT/tmp/hexagonrpc-aarch64.ini" \
		-Dhexagonrpcd_verbose=true \
		--buildtype=release
fi
ninja -C "$BUILD" hexagonrpcd/hexagonrpcd

install -d "$OUT"
install -m755 "$BUILD/hexagonrpcd/hexagonrpcd" "$OUT/hexagonrpcd"
shopt -s nullglob
for so in "$BUILD/libhexagonrpc/"libhexagonrpc.so*; do
	[[ -f "$so" || -L "$so" ]] || continue
	cp -a "$so" "$OUT/"
done
file "$OUT/hexagonrpcd"
"${CROSS}readelf" -d "$OUT/hexagonrpcd" | grep -E "NEEDED|RPATH|RUNPATH" || true
echo "hexagonrpcd: $OUT/hexagonrpcd"
