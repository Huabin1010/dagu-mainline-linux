#!/bin/sh
# Stamp every Wi-Fi profile so NetworkManager arms ath11k wowlan
# instead of DEAUTH_LEAVING. Enable QCA6390 / PCIe RC wakeup.
# Magic packet only (see 20-dagu-wifi-wowlan.conf). Safe to re-run.
# Does not bring the link down.

set -eu

WOW='magic'

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
	[ "$cur" = "$WOW" ] && continue
	nmcli connection modify "$uuid" 802-11-wireless.wake-on-wlan "$WOW" || true
done

# Arm now so the next s2idle does not wait for a reconnect. The phy
# index moves when ath11k rebinds (phy0, phy1, ...): ask the netdev.
# Fails cleanly if the iface is down.
phy=$(cat /sys/class/net/wlp1s0/phy80211/name 2>/dev/null || true)
if command -v iw >/dev/null 2>&1 && [ -n "$phy" ]; then
	iw phy "$phy" wowlan enable magic-packet >/dev/null 2>&1 || true
fi
