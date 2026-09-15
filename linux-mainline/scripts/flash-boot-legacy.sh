#!/usr/bin/env bash
# Flash elish-style header-0 boot to slot B only. Slot A stays HyperOS.
#   erase dtbo_b  (no magic — not dtbo-empty.img)
#   flash vbmeta_b (verify off)
#   flash boot_b
#   set_active b
# Does not write boot_a, dtbo_a, vendor_boot_*, userdata, super, xbl, abl.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/fastboot-common.sh
source "$ROOT/scripts/fastboot-common.sh"

BOOTIMG="${BOOTIMG:-$ROOT/out/boot-dagu-legacy.img}"
VBMETA="${VBMETA:-$ROOT/out/vbmeta-disabled.img}"
DUMP="$ROOT/../dumps/dagu-20260826-210700-root/images"
CMD="${1:-flash}"

flash_b() {
	wait_fastboot
	assert_unlocked
	local prod
	prod=$(fbvar product || true)
	[[ "$prod" == dagu ]] || {
		echo "error: product='$prod' (expected dagu)" >&2
		exit 1
	}
	[[ -f "$BOOTIMG" ]] || {
		echo "missing $BOOTIMG — ./scripts/build-bootimg-legacy.sh" >&2
		exit 1
	}
	[[ -f "$VBMETA" ]] || python3 "$ROOT/scripts/build-chain-extras.py"
	print_ab_status
	echo
	echo "Legacy (elish) path, SLOT B ONLY:"
	echo "  vbmeta_b <- $VBMETA"
	echo "  erase    dtbo_b"
	echo "  boot_b   <- $BOOTIMG"
	echo "  set_active b"
	echo "  leave    A slot + vendor_boot_* + dtbo_a"
	echo
	python3 "$FBUSB" flash vbmeta_b "$VBMETA"
	python3 "$FBUSB" erase dtbo_b
	python3 "$FBUSB" flash boot_b "$BOOTIMG"
	python3 "$FBUSB" set-active b
	echo "==> reboot"
	python3 "$FBUSB" reboot || echo "reboot cmd sent (no OKAY is ok)"
	echo
	echo "Expect: not back at 18d1:d00d in ~6s (that is ABL reject)."
	echo "Logo freeze + USB dark = jumped. Host: ./scripts/usb-connect.sh"
	echo "Brick recovery: $0 restore-a   then hold Vol- + Power"
}

restore_a() {
	wait_fastboot
	echo "Restoring HyperOS on slot A (does not rewrite B)."
	python3 "$FBUSB" flash dtbo_a "$DUMP/dtbo_a.img"
	python3 "$FBUSB" flash vendor_boot_a "$DUMP/vendor_boot_a.img"
	python3 "$FBUSB" flash boot_a "$DUMP/boot_a.img"
	python3 "$FBUSB" flash vbmeta_a "$DUMP/vbmeta_a.img"
	python3 "$FBUSB" set-active a
	python3 "$FBUSB" reboot || true
}

restore_b_stock() {
	wait_fastboot
	echo "Restoring stock B chain (dtbo/vendor_boot/boot/vbmeta)."
	python3 "$FBUSB" flash dtbo_b "$DUMP/dtbo_b.img"
	python3 "$FBUSB" flash vendor_boot_b "$DUMP/vendor_boot_b.img"
	python3 "$FBUSB" flash boot_b "$DUMP/boot_b.img"
	python3 "$FBUSB" flash vbmeta_b "$DUMP/vbmeta_b.img"
}

case "$CMD" in
flash) flash_b ;;
restore-a) restore_a ;;
restore-b-stock) restore_b_stock ;;
*)
	echo "usage: $0 [flash|restore-a|restore-b-stock]" >&2
	exit 1
	;;
esac
