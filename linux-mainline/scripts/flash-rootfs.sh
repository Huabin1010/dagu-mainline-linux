#!/usr/bin/env bash
# Flash Ubuntu to userdata. Wipes Android userspace.
# Does not write boot_a/boot_b/dtbo/super — A/B boot chain stays stock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/fastboot-common.sh
source "$ROOT/scripts/fastboot-common.sh"
IMG="${IMG:-$ROOT/out/rootfs.ext4}"
WAIT="${WAIT:-60}"

[[ -f "$IMG" ]] || { echo "missing $IMG — build-rootfs-image.sh" >&2; exit 1; }

wait_fastboot
assert_unlocked
print_ab_status

echo
echo "This only writes userdata (not A/B). Android /data is gone; boot_a and"
echo "boot_b stay stock. fastboot / EDL still work. To get HyperOS back:"
echo "  flash_all / EDL 官方包（不要 lock）。"
echo
echo "Do not: fastboot reboot   (ABL would load Android boot_\$slot, which"
echo "        cannot mount Ubuntu userdata)."
echo "Do:     ./scripts/boot-fastboot.sh"
echo
# dagu max-download-size is 768 MiB; 4G ext4 must be auto-sparsed.
SPARSE="${SPARSE:-256M}"
echo "fastboot flash -S $SPARSE userdata  (not boot_a/boot_b)"
fastboot flash -S "$SPARSE" userdata "$IMG"
echo "==> flashed userdata <- $IMG"
echo "Boot kernel (RAM only): ./scripts/boot-fastboot.sh"
