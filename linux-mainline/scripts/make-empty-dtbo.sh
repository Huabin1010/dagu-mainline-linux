#!/usr/bin/env bash
# All-zero dtbo.img matching dagu dtbo_a (32 MiB).
# ABL then skips CAF overlay and uses the DTB inside boot.img.
# Only flash this if `fastboot boot` immediately returns to fastboot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out/dtbo-empty.img"
SIZE="${DTBO_SIZE:-33554432}"

mkdir -p "$ROOT/out"
dd if=/dev/zero of="$OUT" bs=4096 count=$((SIZE / 4096)) status=none
echo "==> $OUT ($SIZE bytes)"
echo "    fastboot flash dtbo $OUT"
echo "Restore stock:"
echo "    fastboot flash dtbo $ROOT/../dumps/dagu-20260826-210700-root/images/dtbo_a.img"
