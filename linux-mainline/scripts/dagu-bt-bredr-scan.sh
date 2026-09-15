#!/bin/sh
# Telemetry: BR/EDR-only Inquiry. Product UI is GNOME Settings — do not
# StopDiscovery on that session and do not kill gnome-control-center.
# Kernel time-slices GNOME type-7 (no HCI_QUIRK_SIMULTANEOUS_DISCOVERY on
# QCA6390). Do not use hcitool cc. Do not set ControllerMode=bredr.
set -eu

ADDR=${1:-}

if ! busctl status org.bluez >/dev/null 2>&1; then
	echo "bluez is not on the bus" >&2
	exit 1
fi

hci=$(busctl tree org.bluez | awk '/\/org\/bluez\/hci[0-9]+$/{print $NF; exit}')
[ -n "$hci" ] || { echo "no hci adapter" >&2; exit 1; }

busctl call org.bluez "$hci" org.bluez.Adapter1 StopDiscovery >/dev/null 2>&1 || true
busctl call org.bluez "$hci" org.bluez.Adapter1 SetDiscoveryFilter \
	'a{sv}' 1 Transport s bredr
busctl call org.bluez "$hci" org.bluez.Adapter1 StartDiscovery

echo "BR/EDR Inquiry 12s on $hci (pair while the keyboard lamp blinks)"
sleep 12

if [ -n "$ADDR" ]; then
	echo "pair $ADDR — type the PIN on the keyboard"
	bluetoothctl pair "$ADDR" || true
	bluetoothctl trust "$ADDR" || true
	bluetoothctl connect "$ADDR" || true
fi

busctl call org.bluez "$hci" org.bluez.Adapter1 StopDiscovery >/dev/null 2>&1 || true
bluetoothctl devices
