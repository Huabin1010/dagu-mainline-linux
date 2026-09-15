# shellcheck shell=bash
# Shared fastboot helpers. Source from other scripts. dagu is A/B:
#   slotted: boot, dtbo, vendor_boot, vbmeta
#   NOT slotted: userdata, super
# Kernel install (ginkgo-style): flash current-slot boot+dtbo+vbmeta only.
# Never flash the other slot, super, xbl, abl, or userdata unless asked.

# Google platform-tools 37 hangs on this AMD host (USBDEVFS_REAPURB).
# Use scripts/fb-usb.py (exclusive libusb). Optional: sudo scripts/host-usb-fix.sh
FBUSB="${FBUSB:-$ROOT/scripts/fb-usb.py}"

warn_host_usb() {
	if systemctl is-active --quiet fwupd 2>/dev/null; then
		echo "note: fwupd is active (it mis-labels this tablet as a Quectel modem)." >&2
		echo "      flashing uses $FBUSB, not Google fastboot. optional: sudo $ROOT/scripts/host-usb-fix.sh" >&2
	fi
}

wait_fastboot() {
	local wait="${WAIT:-60}" i
	echo "==> waiting for fastboot (${wait}s)"
	for ((i = 1; i <= wait; i++)); do
		if python3 "$FBUSB" devices 2>/dev/null | grep -q .; then
			python3 "$FBUSB" devices
			warn_host_usb
			return 0
		fi
		sleep 1
	done
	echo "error: no fastboot device. adb reboot bootloader, then retry." >&2
	return 1
}

fbvar() {
	python3 "$FBUSB" getvar "$1" 2>/dev/null | awk -F': ' '{gsub(/\r/, "", $2); print $2; exit}'
}

dagu_slot() {
	local s
	s=$(fbvar current-slot)
	s=${s%% *}
	case "$s" in
	a | b) echo "$s" ;;
	*)
		echo "error: current-slot='$s' (expected a or b)" >&2
		return 1
		;;
	esac
}

print_ab_status() {
	local slot unlocked
	slot=$(fbvar current-slot || true)
	unlocked=$(fbvar unlocked || true)
	echo "device:     $(fbvar product || echo dagu)"
	echo "unlocked:   ${unlocked:-?}"
	echo "A/B slot:   ${slot:-?}   (boot_${slot:-?} dtbo_${slot:-?} vendor_boot_${slot:-?})"
	echo "userdata:   not slotted — skip for P0 (ramdisk only)"
	echo "flash slot: boot_${slot:-?} dtbo_${slot:-?} vbmeta_${slot:-?}  (ginkgo-style)"
	echo "never:      other slot, vendor_boot, super, xbl, abl, userdata (unless asked)"
}

assert_unlocked() {
	local u
	u=$(fbvar unlocked || true)
	[[ "$u" == yes ]] || {
		echo "error: bootloader locked (unlocked=$u)" >&2
		return 1
	}
}
