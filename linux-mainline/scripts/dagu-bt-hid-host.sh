#!/bin/sh
# Tablet HID host for GNOME Settings. After Forget, only BLE mice remain
# bonded — whitelist no longer enables SCAN_PAGE. GNOME never writes
# Pairable, so keep connectable/bondable/FastConnectable (PSCAN only, not
# ISCAN). Do not StopDiscovery and do not kill gnome-control-center.
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
