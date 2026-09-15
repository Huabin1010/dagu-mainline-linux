#!/usr/bin/env bash
# Run display-related unit tests for dagu UEFI port.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${ROOT}"
python3 tools/test/test_display.py "$@"
