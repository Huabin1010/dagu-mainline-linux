#!/usr/bin/env bash
# Attach to dagu USB ACM console (ttyACM*) after gadget enumerates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

dev=""
for _ in $(seq 1 60); do
	for d in /dev/ttyACM*; do
		[[ -e "$d" ]] || continue
		if lsusb | grep -q '1d6b:0104'; then
			dev="$d"
			break 2
		fi
	done
	sleep 1
done

if [[ -z "$dev" ]]; then
	echo "no ttyACM for 1d6b:0104 — is the tablet booted with USB gadget?" >&2
	lsusb | grep -iE '1d6b|18d1|Google' || true
	exit 1
fi

echo "==> $dev (115200 8N1, Ctrl+A then X to exit screen)"
exec screen "$dev" 115200
