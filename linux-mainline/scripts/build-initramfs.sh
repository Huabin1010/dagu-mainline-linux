#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out"
STAGING="$OUT/initramfs-staging"
IMAGE="$OUT/initramfs.cpio.gz"
INIT_BIN="$OUT/initramfs-init"
SH_BIN="$OUT/initramfs-minish"
CC="${CC:-aarch64-linux-gnu-gcc}"

mkdir -p "$OUT"
echo "==> static aarch64 init + minish (DAGU_PID1_PING=${DAGU_PID1_PING:-0})"
"$CC" -static -Os -Wall -Wextra -DDAGU_PID1_PING="${DAGU_PID1_PING:-0}" -o "$INIT_BIN" "$ROOT/initramfs/init.c"
"$CC" -static -Os -Wall -Wextra -o "$SH_BIN" "$ROOT/initramfs/minish.c"

"$ROOT/scripts/build-dropbear.sh" || true
"$ROOT/scripts/stage-firmware.sh" || true

if [[ ! -f "$OUT/id_dagu" ]]; then
	ssh-keygen -t ed25519 -f "$OUT/id_dagu" -N '' -C dagu-ramdisk >/dev/null
	echo "==> SSH key $OUT/id_dagu"
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"/{bin,sbin,etc/dropbear,lib/firmware,proc,sys,dev,root/.ssh}
chmod 700 "$STAGING/root/.ssh"
install -m 755 "$INIT_BIN" "$STAGING/init"
install -m 755 "$SH_BIN" "$STAGING/bin/sh"
ln -sf ../init "$STAGING/sbin/init"
printf 'root:x:0:0:root:/root:/bin/sh\n' >"$STAGING/etc/passwd"
printf 'root:x:0:\n' >"$STAGING/etc/group"
printf 'root::0:0:99999:7:::\n' >"$STAGING/etc/shadow"
install -m 600 "$OUT/id_dagu.pub" "$STAGING/root/.ssh/authorized_keys"

if [[ -x "$OUT/dropbear" ]]; then
	install -m 755 "$OUT/dropbear" "$STAGING/bin/dropbear"
fi

if [[ -x "$OUT/pd-mapper" ]]; then
	install -m 755 "$OUT/pd-mapper" "$STAGING/bin/pd-mapper"
fi

FW="$ROOT/firmware/dagu/lib/firmware"
if [[ -d "$FW" ]]; then
	cp -a "$FW/." "$STAGING/lib/firmware/"
fi

(
	cd "$STAGING"
	find . -print0 | cpio --null -o --format=newc
) | gzip -9 >"$IMAGE"

ls -lh "$IMAGE"
echo "SSH: ssh -i $OUT/id_dagu -o StrictHostKeyChecking=no root@192.168.7.2"
