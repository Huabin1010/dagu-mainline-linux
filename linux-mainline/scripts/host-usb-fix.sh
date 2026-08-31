#!/usr/bin/env bash
# AMD Ryzen + Xiaomi fastboot: `fastboot devices` works, `getvar`/`flash` hang.
#
# 1. USB2 hardware LPM on 18d1:d00d (kernel quirk k = USB_QUIRK_NO_LPM)
# 2. fwupd fastboot plugin claims the tablet as "Quectel EG25-G"
#
# Needs root. Does not flash the tablet.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UDEV_SRC="$ROOT/host/99-dagu-fastboot-nolpm.rules"
UDEV_DST="/etc/udev/rules.d/99-dagu-fastboot-nolpm.rules"

[[ $(id -u) -eq 0 ]] || {
	echo "run: sudo $0" >&2
	exit 1
}

find_dev() {
	local d
	for d in /sys/bus/usb/devices/*; do
		[[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
		if grep -qx 18d1 "$d/idVendor" && grep -qx d00d "$d/idProduct"; then
			echo "$d"
			return 0
		fi
	done
	return 1
}

echo "==> stop fwupd (it enumerates 18d1:d00d as a modem)"
systemctl stop fwupd.service fwupd.socket 2>/dev/null || true

if [[ -d /etc/fwupd ]]; then
	# fwupd 2.x: drop-in. Keep other plugins.
	mkdir -p /etc/fwupd/fwupd.conf.d
	cat >/etc/fwupd/fwupd.conf.d/99-dagu-no-fastboot.conf <<'EOF'
[fwupd]
DisabledPlugins=fastboot
EOF
	echo "    wrote /etc/fwupd/fwupd.conf.d/99-dagu-no-fastboot.conf"
fi

echo "==> usbcore.quirks += 18d1:d00d:k (NO_LPM)"
cur=$(cat /sys/module/usbcore/parameters/quirks 2>/dev/null || true)
if [[ "$cur" != *18d1:d00d:k* ]]; then
	if [[ -n "$cur" ]]; then
		echo "${cur},18d1:d00d:k" >/sys/module/usbcore/parameters/quirks
	else
		echo "18d1:d00d:k" >/sys/module/usbcore/parameters/quirks
	fi
fi
echo "    quirks=$(cat /sys/module/usbcore/parameters/quirks)"

if [[ -f "$UDEV_SRC" ]]; then
	cp -f "$UDEV_SRC" "$UDEV_DST"
	udevadm control --reload-rules || true
	echo "    installed $UDEV_DST"
fi

dev=$(find_dev || true)
if [[ -n "$dev" ]]; then
	echo "==> disable USB2 LPM on $dev"
	if [[ -w "$dev/power/usb2_hardware_lpm" ]]; then
		echo 0 >"$dev/power/usb2_hardware_lpm"
	fi
	echo "    lpm=$(cat "$dev/power/usb2_hardware_lpm" 2>/dev/null || echo '?')"
	echo "==> bounce USB port (clears ABL stuck in download)"
	# authorized 0/1 often does not re-enumerate this AMD xHCI port.
	# usb1-portN/disable actually drops VBUS and recovers ABL.
	port=$(readlink -f "$dev/port" 2>/dev/null || true)
	if [[ -n "$port" && -e "$port/disable" ]]; then
		echo 1 >"$port/disable"
		sleep 8
		echo 0 >"$port/disable"
		sleep 4
	else
		echo 0 >"$dev/authorized"
		sleep 2
		echo 1 >"$dev/authorized"
		sleep 2
	fi
else
	echo "no 18d1:d00d yet — plug / re-enter fastboot after this script"
fi

echo "==> probe via fb-usb.py (8s)"
FBUSB="$ROOT/scripts/fb-usb.py"
if python3 "$FBUSB" getvar product; then
	python3 "$FBUSB" getvar current-slot || true
	python3 "$FBUSB" getvar max-download-size || true
	echo "OK — protocol works. Flash with ./scripts/flash-boot.sh"
else
	echo "getvar still failed. Unplug USB, wait 3s, replug, re-run this script." >&2
	echo "Do not use Google fastboot flash -S on boot/vendor_boot." >&2
	exit 1
fi
