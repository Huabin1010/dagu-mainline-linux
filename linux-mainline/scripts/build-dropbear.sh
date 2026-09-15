#!/usr/bin/env bash
# Static aarch64 dropbear for ramdisk SSH (pubkey only; minish is the shell).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out"
BIN="$OUT/dropbear"
SRC="$OUT/dropbear-src"
CC="${CC:-aarch64-linux-gnu-gcc}"

if [[ -x "$BIN" ]]; then
	echo "dropbear already at $BIN"
	exit 0
fi

mkdir -p "$OUT"
if [[ ! -d "$SRC/.git" ]]; then
	git clone --depth 1 --branch DROPBEAR_2024.86 \
		https://github.com/mkj/dropbear.git "$SRC" || \
	git clone --depth 1 https://github.com/mkj/dropbear.git "$SRC"
fi

cd "$SRC"
# Cross libc has no crypt(); ramdisk uses authorized_keys anyway.
cat > localoptions.h <<'EOF'
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PAM_AUTH 0
EOF

export CC
# -fPIE/-pie from --enable-harden fights -static
./configure --host=aarch64-linux-gnu --disable-zlib --disable-syslog \
	--disable-lastlog --disable-utmp --disable-wtmp --disable-harden \
	--prefix=/usr >/tmp/dropbear-cfg.log 2>&1 || {
	echo "warn: dropbear configure failed (see /tmp/dropbear-cfg.log)" >&2
	exit 0
}
make PROGRAMS="dropbear" STATIC=1 -j"$(nproc)" >/tmp/dropbear-build.log 2>&1 || {
	echo "warn: dropbear build failed (see /tmp/dropbear-build.log)" >&2
	exit 0
}
cp -f dropbear "$BIN"
echo "==> $BIN"
file "$BIN"
