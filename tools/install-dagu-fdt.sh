#!/usr/bin/env bash
# Copy the live HyperOS FDT into the dagu UEFI port. Do not compile Linux 7.0 DTS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${ROOT}/dumps/dagu-20260826-210700-root/dt/fdt.dtb}"
DST="${ROOT}/port/dagu/Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb"
HASH="${DST}.sha256"

if [[ ! -f "${SRC}" ]]; then
  echo "[install-dagu-fdt] missing ${SRC}" >&2
  echo "Collect live FDT per docs/hardware-debug-workflow.md. Do not use Linux 7.0 dtc output." >&2
  exit 2
fi

mkdir -p "$(dirname "${DST}")"

python3 - "${SRC}" <<'PY'
import sys
from pathlib import Path
blob = Path(sys.argv[1]).read_bytes().lower()
if b"dagu" not in blob:
    sys.exit("no dagu string")
if b"l81a" not in blob:
    sys.exit("no l81a panel string")
if b"elish" in blob and b"dagu" not in blob:
    sys.exit("elish FDT without dagu")
if b"nabu" in blob and b"dagu" not in blob:
    sys.exit("nabu FDT without dagu")
PY

cp -f "${SRC}" "${DST}"
sha256sum "${DST}" | awk '{print $1}' > "${HASH}"
echo "[install-dagu-fdt] ${SRC} -> ${DST}"
echo "[install-dagu-fdt] sha256 $(cat "${HASH}")"
python3 - "${DST}" <<'PY'
from pathlib import Path
b = Path(__import__("sys").argv[1]).read_bytes()
for needle in (b"xiaomi dagu", b"l81a", b"L81A", b"qcom,dagu"):
    print(" ", needle.decode("ascii", "replace"), "OK" if needle.lower() in b.lower() else "MISSING")
PY
