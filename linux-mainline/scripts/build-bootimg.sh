#!/usr/bin/env bash
# Pack boot.img header v2 + DTB in the image (ginkgo method).
# Stock HyperOS boot.img is header v3 (DTB lives in vendor_boot). A v2
# image is what we want for `fastboot boot` so ABL does not pick CAF DTB.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

OUT="$ROOT/out"
KERNEL="$OUT/Image.gz"
DTB="$OUT/$DTB_NAME"
RAMDISK="$OUT/initramfs.cpio.gz"
BOOTIMG="${BOOTIMG:-$OUT/boot-dagu.img}"

PAGESIZE=4096
BASE=0x00000000
KERNEL_OFFSET=0x00008000
RAMDISK_OFFSET=0x01000000
SECOND_OFFSET=0x00f00000
TAGS_OFFSET=0x00000100
DTB_OFFSET=0x01f00000
HEADER_VERSION=2
OS_VERSION=14.0.0
OS_PATCH_LEVEL=2025-07

# uart6 = GENI @ 0x988000 on SM8250 (matches live serial0).
# tty0 last so simplefb/fbcon can take /dev/console if splash is mapped.
# pd_ignore_unused: SM8250 bring-up; clk_ignore_unused: ginkgo lesson.
CMDLINE="${CMDLINE:-console=ttyMSM0,115200n8 console=tty0 earlycon=qcom_geni,0x988000 keep_bootcon ignore_loglevel loglevel=8 clk_ignore_unused pd_ignore_unused fw_devlink.sync_state=disabled}"

[[ -f "$KERNEL" ]] || { echo "run build-kernel.sh" >&2; exit 1; }
[[ -f "$DTB" ]] || { echo "run build-kernel.sh" >&2; exit 1; }

"$ROOT/scripts/build-initramfs.sh"

echo "==> mkbootimg header v2 + $DTB_NAME"
mkbootimg \
	--header_version "$HEADER_VERSION" \
	--kernel "$KERNEL" \
	--dtb "$DTB" \
	--ramdisk "$RAMDISK" \
	--cmdline "$CMDLINE" \
	--pagesize "$PAGESIZE" \
	--base "$BASE" \
	--kernel_offset "$KERNEL_OFFSET" \
	--ramdisk_offset "$RAMDISK_OFFSET" \
	--second_offset "$SECOND_OFFSET" \
	--tags_offset "$TAGS_OFFSET" \
	--dtb_offset "$DTB_OFFSET" \
	--os_version "$OS_VERSION" \
	--os_patch_level "$OS_PATCH_LEVEL" \
	-o "$BOOTIMG"

unpack_bootimg --boot_img "$BOOTIMG" --out /tmp/verify-dagu-boot 2>&1 | head -20
ls -lh "$BOOTIMG"
echo "Boot (do not flash):  ./scripts/boot-fastboot.sh"
