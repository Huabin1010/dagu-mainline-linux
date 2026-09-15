#!/bin/sh
# Tablet HID host for GNOME Settings. After Forget, only BLE mice remain
# bonded — whitelist no longer enables SCAN_PAGE. GNOME never writes
# Pairable, so keep connectable/bondable/FastConnectable (PSCAN only, not
# ISCAN). Do not StopDiscovery and do not kill gnome-control-center.
set -eu

for _ in 1 2 3 4 5 6 7 8 9 10; do
	btmgmt info >/dev/null 2>&1 && break
	sleep 0.3
done

btmgmt --index 0 connectable on >/dev/null 2>&1 || true
btmgmt --index 0 bondable on >/dev/null 2>&1 || true
btmgmt --index 0 fast-conn on >/dev/null 2>&1 || true

if command -v bluetoothctl >/dev/null 2>&1; then
	bluetoothctl pairable on >/dev/null 2>&1 || true
fi
