#!/usr/bin/env bash
# Load boot-dagu.img via fastboot boot. Never writes boot_a/boot_b/dtbo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/fastboot-common.sh
source "$ROOT/scripts/fastboot-common.sh"
BOOTIMG="${BOOTIMG:-$ROOT/out/boot-dagu.img}"
WAIT="${WAIT:-60}"

[[ -f "$BOOTIMG" ]] || { echo "missing $BOOTIMG — build-bootimg.sh" >&2; exit 1; }

wait_fastboot
print_ab_status
slot=$(dagu_slot)

echo
echo "RAM boot only. Does not write boot_${slot}, dtbo_${slot}, or userdata."
echo "If the tablet snaps back to fastboot: ./scripts/make-empty-dtbo.sh flash"
echo
fastboot boot "$BOOTIMG"
echo "Host: ./scripts/usb-connect.sh"
echo "SSH:  ./scripts/ssh-run.sh dmesg"
