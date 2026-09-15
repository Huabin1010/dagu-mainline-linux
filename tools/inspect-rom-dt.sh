#!/usr/bin/env bash
set -euo pipefail
ROM_TREE="${1:-vendor/firmware/rom-tree}"
find "$ROM_TREE" -name dtbo.img -o -name vendor_boot.img | head -10
for f in $(find "$ROM_TREE" -name dtbo.img | head -1); do
  echo "=== $f ==="
  ls -lh "$f"
  xxd -l 64 "$f"
done
