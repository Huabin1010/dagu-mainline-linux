#!/usr/bin/env bash
# Extract dagu DTB from stock boot.img, vendor_boot.img (+ optional dtbo.img).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${ROOT}/port/dagu/Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb"
SRC="${1:-}"
DTBO="${2:-}"

usage() {
  cat <<EOF
Usage: extract-dagu-dtb.sh <boot.img|vendor_boot.img> [dtbo.img]

Extracts dagu.dtb into:
  port/dagu/Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb

When dtbo.img is provided (HyperOS / Android 11+), merges vendor_boot base DTB
with the dagu overlay from dtbo.img.
EOF
}

if [[ -z "${SRC}" ]]; then
  usage >&2
  exit 2
fi
if [[ ! -f "${SRC}" ]]; then
  echo "[extract-dagu-dtb] not found: ${SRC}" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUT}")"

if [[ -n "${DTBO}" ]]; then
  if [[ ! -f "${DTBO}" ]]; then
    echo "[extract-dagu-dtb] dtbo not found: ${DTBO}" >&2
    exit 1
  fi
  python3 "${SCRIPT_DIR}/merge-dagu-dtb.py" "${SRC}" "${DTBO}" "${OUT}"
  echo "[extract-dagu-dtb] OK -> ${OUT}"
  fdtdump "${OUT}" 2>/dev/null | grep -E 'model =|mdss-dsi-panel-name|l81a' | head -10
  exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

python3 - "${SRC}" "${WORK}" "${OUT}" <<'PY'
import struct
import subprocess
import sys
from pathlib import Path

src = Path(sys.argv[1])
work = Path(sys.argv[2])
out = Path(sys.argv[3])
data = src.read_bytes()


def split_dtbs(blob: bytes, out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    magic = b"\xd0\x0d\xfe\xed"
    idx = 0
    paths: list[Path] = []
    n = 0
    while True:
        pos = blob.find(magic, idx)
        if pos < 0:
            break
        if pos + 8 > len(blob):
            break
        size = struct.unpack(">I", blob[pos + 4 : pos + 8])[0]
        if size < 0x28 or pos + size > len(blob):
            idx = pos + 4
            continue
        path = out_dir / f"part-{n:03d}.dtb"
        path.write_bytes(blob[pos : pos + size])
        paths.append(path)
        n += 1
        idx = pos + size
    return paths


def unpack_vendor_boot(blob: bytes) -> bytes | None:
    if len(blob) < 0x30 or blob[:8] != b"VNDRBOOT":
        return None
    page_size = struct.unpack_from("<I", blob, 12)[0]
    vendor_ramdisk_size = struct.unpack_from("<I", blob, 24)[0]
    header_size = struct.unpack_from("<I", blob, 2096)[0]
    dtb_size = struct.unpack_from("<I", blob, 2100)[0]
    if page_size <= 0 or dtb_size <= 0:
        return None

    def pages(n: int) -> int:
        return (n + page_size - 1) // page_size

    dtb_off = page_size * (pages(header_size) + pages(vendor_ramdisk_size))
    if dtb_off + dtb_size > len(blob):
        return None
    return blob[dtb_off : dtb_off + dtb_size]


def fdtdump_text(dtb: Path) -> str:
    try:
        return subprocess.check_output(
            ["fdtdump", str(dtb)], stderr=subprocess.STDOUT, text=True
        )
    except Exception:
        return ""


candidates: list[Path] = []
vendor_dtb = unpack_vendor_boot(data)
if vendor_dtb:
    candidates.extend(split_dtbs(vendor_dtb, work / "vendor"))
candidates.extend(split_dtbs(data, work / "scan"))

seen: set[bytes] = set()
unique: list[Path] = []
for path in candidates:
    blob = path.read_bytes()
    if blob in seen:
        continue
    seen.add(blob)
    unique.append(path)

if not unique:
    print("[extract-dagu-dtb] ERROR: no DTB blobs found", file=sys.stderr)
    sys.exit(1)

picked: Path | None = None
for dtb in unique:
    txt = fdtdump_text(dtb)
    if "xiaomi dagu" in txt.lower():
        picked = dtb
        break
if picked is None:
    for dtb in unique:
        txt = fdtdump_text(dtb)
        if "l81a" in txt.lower() or "board-id = <51" in txt:
            picked = dtb
            break
if picked is None:
    print("[extract-dagu-dtb] available models:", file=sys.stderr)
    for dtb in unique:
        txt = fdtdump_text(dtb)
        model = next((line.strip() for line in txt.splitlines() if "model =" in line), "?")
        print(f"  {dtb.name}: {model}", file=sys.stderr)
    sys.exit(1)

out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(picked.read_bytes())
print(picked)
PY

echo "[extract-dagu-dtb] OK -> ${OUT}"
fdtdump "${OUT}" 2>/dev/null | grep -E 'model =|mdss-dsi-panel-name|l81a' | head -10
