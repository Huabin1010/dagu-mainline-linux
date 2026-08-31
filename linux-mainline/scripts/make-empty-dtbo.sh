#!/usr/bin/env bash
# Flash 0-overlay DTBO. dagu ABL rejects count=0 (~6s bounce). Prefer dtbo-stub.img.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/fastboot-common.sh
source "$ROOT/scripts/fastboot-common.sh"
DUMP="$ROOT/../dumps/dagu-20260826-210700-root/images"
WAIT="${WAIT:-60}"
CMD="${1:-}"

python3 "$ROOT/scripts/build-chain-extras.py"
OUT="$ROOT/out/dtbo-empty.img"

case "$CMD" in
flash)
	wait_fastboot
	echo "Empty DTBO (0 overlays) on BOTH slots"
	python3 "$FBUSB" flash dtbo_a "$OUT"
	python3 "$FBUSB" flash dtbo_b "$OUT"
	echo "Restore: $0 restore"
	;;
restore)
	wait_fastboot
	python3 "$FBUSB" flash dtbo_a "$DUMP/dtbo_a.img"
	python3 "$FBUSB" flash dtbo_b "$DUMP/dtbo_b.img"
	;;
*)
	echo "usage: $0 [flash|restore]" >&2
	exit 1
	;;
esac
