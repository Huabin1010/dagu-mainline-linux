#!/usr/bin/env bash
# Pull dmesg over RNDIS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/out/dmesg-dagu.txt}"
"$ROOT/scripts/ssh-run.sh" dmesg >"$OUT"
echo "==> $OUT"
