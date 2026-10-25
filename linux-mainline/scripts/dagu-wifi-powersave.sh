#!/bin/sh
# Wi-Fi power save follows the charger.
#
# QCA6390 with power save on sleeps 100 ms after the last packet, and the
# AP holds the next one until the radio wakes. Gateway ping measured on
# CMCC-9ff4-5G at -44 dBm:
#   power save on   avg 7.4 ms, max 14.7 ms, jitter 5.5 ms
#   power save off  avg 2.4 ms, max  2.8 ms, jitter 0.2 ms
# Throughput is the same (the radio stays awake under load). The cost of
# "off" is idle radio power, so keep it on battery only.
#
# Called by udev on charger change and by the NetworkManager dispatcher on
# "up", because NetworkManager writes wifi.powersave again on every
# activation. s2idle is unaffected: WoWLAN firmware owns the radio there.
set -eu

ac=0
for p in /sys/class/power_supply/*; do
	[ -r "$p/type" ] || continue
	case "$(cat "$p/type")" in
	USB | Mains) ;;
	*) continue ;;
	esac
	if [ "$(cat "$p/online" 2>/dev/null || echo 0)" = 1 ]; then
		ac=1
		break
	fi
done
want=on
[ "$ac" = 1 ] && want=off

for dev in $(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }'); do
	cur=$(iw dev "$dev" get power_save 2>/dev/null | awk '{ print $3 }')
	[ "$cur" = "$want" ] && continue
	iw dev "$dev" set power_save "$want" 2>/dev/null || continue
	logger -t dagu-wifi-powersave "$dev power_save $cur -> $want (ac=$ac)"
done
exit 0
