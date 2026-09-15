#!/usr/bin/env bash
# Copy aarch64 e2fsck/resize2fs + loader/libs from the live tablet
# into out/e2fsprogs-aarch64 for build-initramfs.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out/e2fsprogs-aarch64"
HOST="${1:-192.168.7.2}"
KEY="${DAGU_SSH_KEY:-$ROOT/out/id_dagu}"

rm -rf "$OUT"
mkdir -p "$OUT"/{sbin,lib,usr/lib}

ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	"root@$HOST" 'tar -C / -chf - \
	usr/sbin/e2fsck usr/sbin/resize2fs \
	lib/ld-linux-aarch64.so.1 \
	usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
	usr/lib/aarch64-linux-gnu/libext2fs.so.2 \
	usr/lib/aarch64-linux-gnu/libcom_err.so.2 \
	usr/lib/aarch64-linux-gnu/libblkid.so.1 \
	usr/lib/aarch64-linux-gnu/libuuid.so.1 \
	usr/lib/aarch64-linux-gnu/libe2p.so.2 \
	usr/lib/aarch64-linux-gnu/libc.so.6' \
	| tar -C "$OUT" -xf -

install -m 755 "$OUT/usr/sbin/e2fsck" "$OUT/sbin/e2fsck"
install -m 755 "$OUT/usr/sbin/resize2fs" "$OUT/sbin/resize2fs"
mkdir -p "$OUT/lib/aarch64-linux-gnu"
if [[ -d "$OUT/usr/lib/aarch64-linux-gnu" ]]; then
	cp -a "$OUT/usr/lib/aarch64-linux-gnu/." "$OUT/lib/aarch64-linux-gnu/"
fi
ln -sfn aarch64-linux-gnu/ld-linux-aarch64.so.1 "$OUT/lib/ld-linux-aarch64.so.1"
echo "==> $OUT"
find "$OUT" -type f -o -type l | sort
