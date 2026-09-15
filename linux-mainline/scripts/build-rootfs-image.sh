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
# truncate/fallocate leave SEEK_HOLE extents. Google fastboot -S turns those
# into don't-care chunks, so the ext4 journal (often at ~8G on a 16G image)
# is never written and the tablet stays on ramdisk:
#   JBD2: no valid journal superblock found
count_mib="${SIZE^^}"
case "$count_mib" in
	*G) count_mib=$(( ${count_mib%G} * 1024 )) ;;
	*M) count_mib=$(( ${count_mib%M} )) ;;
	*) echo "SIZE must look like 8G or 4096M" >&2; exit 1 ;;
esac
dd if=/dev/zero of="$IMG" bs=1M count="$count_mib" status=progress
# nodiscard: otherwise mke2fs punches SEEK_HOLE in the image and the journal
# is never sent by fastboot -S (JBD2: no valid journal superblock).
mkfs.ext4 -F -L dagu-linux -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 -d "$ROOTFS" "$IMG"
# mke2fs still leaves unwritten extents; materialize them. fastboot -S maps
# SEEK_HOLE to don't-care and would skip the journal.
dd if="$IMG" of="${IMG}.full" bs=1M status=progress
mv -f "${IMG}.full" "$IMG"
chmod 644 "$IMG" || true
echo "==> $IMG"
echo "Flash (wipes Android): ./scripts/flash-rootfs.sh"
ls -lh "$IMG"
