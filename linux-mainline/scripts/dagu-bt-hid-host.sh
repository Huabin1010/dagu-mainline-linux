#!/bin/sh
# Tablet HID host for GNOME Settings. After Forget, only BLE mice remain
# bonded — whitelist no longer enables SCAN_PAGE. GNOME setup-mode writes
# Pairable off when the user clicks Connect, and an HCI Hardware Failure
# (Add Device 0x03) re-runs QCA setup without udev add. Keep
# connectable/bondable/FastConnectable (PSCAN only, not ISCAN).
# Device-initiated HID (K380): GNOME Connect must not outgoing-page;
# bluetoothd waits for the keypress while this script keeps PSCAN.
# Do not StopDiscovery and do not kill gnome-control-center.
# btmgmt/bluetoothctl can block on a down mgmt socket; cap each call.
#
# btmgmt reads commands from stdin through epoll. systemd and udev give
# a service /dev/null, epoll refuses that fd, and btmgmt then waits
# until timeout without sending anything. Every call here timed out
# (10 x 1 s + 3 x 2 s), so connectable was never set and PSCAN stayed
# off. An empty pipe is pollable and reads as EOF.
set -eu

bt() { : | timeout 2 btmgmt --index 0 "$@" >/dev/null 2>&1 || true; }

# bluetoothd sends Set Connectable off as soon as Set Powered completes
# (QCA firmware download, about 1.4 s). Anything written before that is
# overwritten, so wait for "powered" in the current settings.
i=0
while [ "$i" -lt 20 ]; do
	if : | timeout 1 btmgmt --index 0 info 2>/dev/null |
		grep -q 'current settings: powered'; then
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
