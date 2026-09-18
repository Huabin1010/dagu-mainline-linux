#!/usr/bin/env bash
# Flash or restore BOTH A/B slots. Xiaomi often restores the other slot if only one is written.
# Images must be magiskboot-repacked stock v3 (see build-bootimg.sh). No userdata.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/fastboot-common.sh
source "$ROOT/scripts/fastboot-common.sh"

BOOTIMG="${BOOTIMG:-$ROOT/out/boot-dagu.img}"
VBOOT="${VBOOT:-$ROOT/out/vendor_boot-dagu.img}"
# count=0 empty DTBO makes this ABL bounce in ~6s. Stub keeps 29 board-ids.
DTBO="${DTBO:-$ROOT/out/dtbo-stub.img}"
VBMETA="${VBMETA:-$ROOT/out/vbmeta-disabled.img}"
DUMP="$ROOT/../dumps/dagu-20260826-210700-root/images"
WAIT="${WAIT:-60}"
CMD="${1:-flash}"

case "$CMD" in
flash-b)
	wait_fastboot
	assert_unlocked
	python3 "$ROOT/scripts/build-chain-extras.py"
	[[ -f "$BOOTIMG" && -f "$VBOOT" && -f "$DTBO" ]] || {
		echo "missing images — build-bootimg.sh" >&2
		exit 1
	}
	print_ab_status
	echo
	echo "v3 path, SLOT B ONLY (A slot TWRP untouched):"
	echo "  dtbo_b        <- $DTBO"
	echo "  vbmeta_b      <- $VBMETA"
	echo "  vendor_boot_b <- $VBOOT"
	echo "  boot_b        <- $BOOTIMG"
	echo "  set_active b"
	echo
	python3 "$FBUSB" flash dtbo_b "$DTBO"
	python3 "$FBUSB" flash vbmeta_b "$VBMETA"
	python3 "$FBUSB" flash vendor_boot_b "$VBOOT"
	python3 "$FBUSB" flash boot_b "$BOOTIMG"
	python3 "$FBUSB" set-active b
	echo "==> reboot (timeout: ABL drops USB, no OKAY)"
	timeout 3 python3 "$FBUSB" reboot || echo "reboot cmd sent (no OKAY is ok)"
	echo "Host: ./scripts/usb-connect.sh"
	echo "Brick recovery: ../scripts/flash-boot-legacy.sh restore-a"
	;;
flash)
	wait_fastboot
	python3 "$ROOT/scripts/build-chain-extras.py"
	[[ -f "$BOOTIMG" && -f "$VBOOT" ]] || {
		echo "missing $BOOTIMG or $VBOOT — build-bootimg.sh" >&2
		exit 1
	}
	echo
	echo "Both slots via fb-usb.py. Stub DTBO (not empty), vbmeta verify off."
	echo "  dtbo_a/b        <- $DTBO"
	echo "  vbmeta_a/b      <- $VBMETA"
	echo "  vendor_boot_a/b <- $VBOOT"
	echo "  boot_a/b        <- $BOOTIMG"
	echo
	python3 "$FBUSB" flash dtbo_a "$DTBO"
	python3 "$FBUSB" flash dtbo_b "$DTBO"
	python3 "$FBUSB" flash vbmeta_a "$VBMETA"
	python3 "$FBUSB" flash vbmeta_b "$VBMETA"
	python3 "$FBUSB" flash vendor_boot_a "$VBOOT"
	python3 "$FBUSB" flash vendor_boot_b "$VBOOT"
	python3 "$FBUSB" flash boot_a "$BOOTIMG"
	python3 "$FBUSB" flash boot_b "$BOOTIMG"
	echo "==> reboot (timeout: ABL drops USB, no OKAY)"
	timeout 3 python3 "$FBUSB" reboot || echo "reboot cmd sent (no OKAY is ok)"
	echo "Host: ./scripts/usb-connect.sh"
	echo "Restore: $0 restore"
	;;
restore)
	wait_fastboot
	echo
	echo "Restoring stock boot chain on BOTH slots (no userdata) via fb-usb.py"
	python3 "$FBUSB" flash dtbo_a "$DUMP/dtbo_a.img"
	python3 "$FBUSB" flash dtbo_b "$DUMP/dtbo_b.img"
	python3 "$FBUSB" flash vendor_boot_a "$DUMP/vendor_boot_a.img"
	python3 "$FBUSB" flash vendor_boot_b "$DUMP/vendor_boot_b.img"
	python3 "$FBUSB" flash boot_a "$DUMP/boot_a.img"
	python3 "$FBUSB" flash boot_b "$DUMP/boot_b.img"
	python3 "$FBUSB" flash vbmeta_a "$DUMP/vbmeta_a.img"
	python3 "$FBUSB" flash vbmeta_b "$DUMP/vbmeta_b.img"
	python3 "$FBUSB" set-active a || echo "set-active a skipped"
	echo "==> reboot (timeout: ABL drops USB, no OKAY)"
	timeout 3 python3 "$FBUSB" reboot || echo "reboot cmd sent (no OKAY is ok)"
	;;
*)
	echo "usage: $0 [flash|flash-b|restore]" >&2
	exit 1
	;;
esac
