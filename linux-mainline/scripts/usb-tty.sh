#!/usr/bin/env bash
# Attach to dagu USB serial console after g_serial enumerates (gemini path).
# Kernel CONFIG_USB_G_SERIAL → host 0525:a4a7 /dev/ttyACM*
set -euo pipefail

dev=""
for _ in $(seq 1 90); do
	if lsusb | grep -qiE '0525:a4a7|1d6b:0104'; then
		for d in /dev/ttyACM* /dev/ttyUSB*; do
			[[ -e "$d" ]] || continue
			dev="$d"
			break 2
		done
	fi
	sleep 1
done

if [[ -z "$dev" ]]; then
	echo "no USB ACM (want 0525:a4a7 g_serial) — tablet USB gadget not up?" >&2
	lsusb | grep -iE '0525|1d6b|18d1|Google|NetChip' || true
	exit 1
fi

echo "==> $dev (115200 8N1, Ctrl+A then X to exit screen)"
echo "    expect lsusb: 0525:a4a7 (g_serial), not 1d6b:0104 (configfs RNDIS)"
exec screen "$dev" 115200
