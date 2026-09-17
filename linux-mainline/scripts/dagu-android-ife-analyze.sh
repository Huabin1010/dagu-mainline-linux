#!/usr/bin/env bash
# Read-only HyperOS IFE analyzer. NEVER flash that machine.
#   DAGU_ADB_SERIAL=53dcc70 ./scripts/dagu-android-ife-analyze.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DAGU_ADB_SERIAL="${DAGU_ADB_SERIAL:?set DAGU_ADB_SERIAL to the HyperOS tablet}"
exec python3 "$ROOT/scripts/dagu-android-ife-analyze.py" "$@"
