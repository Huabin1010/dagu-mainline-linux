#!/usr/bin/env bash
# Load boot-dagu.img via fastboot boot. Never flashes partitions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTIMG="${BOOTIMG:-$ROOT/out/boot-dagu.img}"
WAIT="${WAIT:-60}"

[[ -f "$BOOTIMG" ]] || { echo "missing $BOOTIMG — build-bootimg.sh" >&2; exit 1; }

echo "==> waiting for fastboot (${WAIT}s)"
for ((i = 1; i <= WAIT; i++)); do
	if fastboot devices | grep -q .; then
		fastboot devices
		break
	fi
	sleep 1
	if [[ "$i" -eq WAIT ]]; then
		echo "error: no fastboot device. adb reboot bootloader, then retry." >&2
		exit 1
	fi
done

echo
echo "RAM boot only. Android boot/dtbo/userdata are not written."
echo "If the tablet snaps back to fastboot: empty DTBO once (make-empty-dtbo.sh)."
echo
fastboot boot "$BOOTIMG"
echo "Host: ./scripts/usb-connect.sh"
echo "SSH:  ./scripts/ssh-run.sh dmesg"
