#!/bin/sh
# Stamp every Wi-Fi profile so NetworkManager arms ath11k wowlan
# instead of DEAUTH_LEAVING. Enable QCA6390 / PCIe RC wakeup.
# Safe to re-run. Does not bring the link down.

set -eu

WOW='disconnect,magic,gtk-rekey-failure'

for pci in /sys/bus/pci/devices/*; do
	[ -f "$pci/vendor" ] || continue
	v=$(cat "$pci/vendor")
	id=$(cat "$pci/device")
	if [ "$v" = "0x17cb" ] && { [ "$id" = "0x1101" ] || [ "$id" = "0x010b" ]; }; then
		echo enabled >"$pci/power/wakeup" 2>/dev/null || true
	fi
done
if [ -f /sys/class/net/wlp1s0/device/power/wakeup ]; then
	echo enabled >/sys/class/net/wlp1s0/device/power/wakeup
fi

command -v nmcli >/dev/null 2>&1 || exit 0

nmcli -t -f UUID,TYPE connection show | while IFS=: read -r uuid type; do
	[ "$type" = "802-11-wireless" ] || continue
	cur=$(nmcli -g 802-11-wireless.wake-on-wlan connection show "$uuid" 2>/dev/null || true)
	case $cur in
	*disconnect*) ;;
	*)
		nmcli connection modify "$uuid" \
			802-11-wireless.wake-on-wlan "$WOW" || true
		;;
	esac
done

# Arm now so the next s2idle does not wait for a reconnect.
# Fails cleanly if the iface is down.
if command -v iw >/dev/null 2>&1 && [ -d /sys/class/ieee80211/phy0 ]; then
	iw phy phy0 wowlan enable disconnect magic-packet gtk-rekey-failure \
		>/dev/null 2>&1 || true
fi
