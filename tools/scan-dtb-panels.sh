#!/usr/bin/env bash
set -euo pipefail
for f in "$@"; do
  echo "=== $(basename "$f") ==="
  fdtdump "$f" 2>/dev/null | grep -E 'model =|mdss-dsi-panel-name|l81a' | head -5 || true
done
