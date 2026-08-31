#!/usr/bin/env bash
# ext4 image for userdata. Replaces Android.
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
echo "Flash (wipes Android): ./scripts/flash-rootfs.sh"
ls -lh "$IMG"
