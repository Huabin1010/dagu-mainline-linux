#!/bin/sh
# Tablet HID host for GNOME Settings. After Forget, only BLE mice remain
# bonded — whitelist no longer enables SCAN_PAGE. GNOME setup-mode writes
# Pairable off when the user clicks Connect, and an HCI Hardware Failure
# (Add Device 0x03) re-runs QCA setup without udev add. Keep
# connectable/bondable/FastConnectable (PSCAN only, not ISCAN).
# Device-initiated HID (K380): GNOME Connect must not outgoing-page;
# bluetoothd waits for the keypress while this script keeps PSCAN.
# Do not StopDiscovery and do not kill gnome-control-center.
# btmgmt/bluetoothctl can block on a down mgmt socket; cap each call so
# bluetooth.service ExecStartPost cannot time out the daemon.
set -eu

bt() { timeout 2 btmgmt --index 0 "$@" >/dev/null 2>&1 || true; }

i=0
while [ "$i" -lt 10 ]; do
	if timeout 1 btmgmt info >/dev/null 2>&1; then
		break
	fi
	i=$((i + 1))
	sleep 0.3
done

bt connectable on
bt bondable on
bt fast-conn on
timeout 2 bluetoothctl pairable on >/dev/null 2>&1 || true
# GNOME Settings 未设置 is !Paired && !Trusted. bluetoothctl pair leaves
# Trusted=no; the row stays 未设置 and Device1.Pair returns AlreadyExists.
# Trust every bonded device so Settings shows Disconnected and Connects.
timeout 3 bluetoothctl devices Paired 2>/dev/null | awk '{print $2}' | while read -r addr; do
	[ -n "$addr" ] || continue
	timeout 2 bluetoothctl trust "$addr" >/dev/null 2>&1 || true
done
