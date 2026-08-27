#!/usr/bin/env bash
# ext4 image for a dedicated Linux partition. Does not target userdata.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$ROOT/out/rootfs}"
IMG="${IMG:-$ROOT/out/rootfs.ext4}"
SIZE="${SIZE:-4G}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
	exec sudo ROOTFS="$ROOTFS" IMG="$IMG" SIZE="$SIZE" "$0" "$@"
fi

[[ -d "$ROOTFS/bin" ]] || { echo "run build-rootfs.sh" >&2; exit 1; }
mkdir -p "$ROOT/out"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
mkfs.ext4 -F -L dagu-linux -d "$ROOTFS" "$IMG"
chmod 644 "$IMG" || true
echo "==> $IMG"
echo "Do not: fastboot flash userdata $IMG"
echo "Do:    pick an unused partition (see linux-mainline/README.md) then flash that name."
ls -lh "$IMG"
