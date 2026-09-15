#!/bin/sh
# Undo the earlier HID "low latency" shortcut: put sniff and UART runtime PM
# back. HID host policy lives in BlueZ (FastConnectable, sniff 6–18,
# UserspaceHID=persist, BR-only find) and the kernel overlay (clock offset,
# Central, interlaced page scan, ACL page-timeout cleanup). This script must
# not disable sniff or pin UART.
set -eu

uart_roots='
/sys/devices/platform/soc@0/9c0000.geniqup/998000.serial
/sys/devices/platform/soc@0/9c0000.geniqup/998000.serial/998000.serial:0
/sys/devices/platform/soc@0/9c0000.geniqup/998000.serial/998000.serial:0/998000.serial:0.0
'
for d in $uart_roots; do
	if [ -w "$d/power/control" ]; then
		echo auto >"$d/power/control" || true
	fi
done

# Default link policy: role-switch + hold + sniff (0x0007). Sniff stays on
# so classic HID can radio-sleep; WakeAllowed still wakes the tablet.
if command -v hcitool >/dev/null 2>&1 && [ -e /sys/class/bluetooth/hci0 ]; then
	hcitool cmd 0x02 0x0f 0x07 0x00 >/dev/null 2>&1 || true
	hcitool con 2>/dev/null | awk '/ACL/{print $3}' | while read -r addr; do
		[ -n "$addr" ] || continue
		hcitool lp "$addr" RSWITCH HOLD SNIFF >/dev/null 2>&1 || true
	done
fi
