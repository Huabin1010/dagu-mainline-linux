#!/usr/bin/env bash
# Convert downloaded UUP files into a Windows 11 ARM64 ISO.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/tools/downloads/win11-arm64"
BIN="${OUT}/.bin/root"
UUPs="${OUT}/UUPs"
CONV="${OUT}/converter"

export PATH="${BIN}/usr/bin:${BIN}/usr/sbin:${PATH}"
export LD_LIBRARY_PATH="${BIN}/usr/lib/x86_64-linux-gnu:${BIN}/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

need() {
  command -v "$1" >/dev/null || {
    echo "[win11-iso] missing $1 — extract debs into ${BIN} first" >&2
    exit 1
  }
}

need aria2c
need wimlib-imagex
need cabextract
need genisoimage
need chntpw

if [[ ! -d "${UUPs}" ]]; then
  echo "[win11-iso] missing ${UUPs}" >&2
  exit 1
fi

# Rough completeness check against meta
if [[ -f "${OUT}/uup-meta.json" ]]; then
  expect="$(python3 -c "import json; print(json.load(open('${OUT}/uup-meta.json'))['nfiles'])")"
  have="$(find "${UUPs}" -type f ! -name '*.aria2' | wc -l)"
  if [[ "${have}" -lt "${expect}" ]]; then
    echo "[win11-iso] UUPs incomplete: ${have}/${expect} files — wait for aria2 or re-run download" >&2
    exit 1
  fi
fi

if [[ ! -x "${CONV}/convert.sh" ]]; then
  echo "[win11-iso] missing converter at ${CONV}" >&2
  exit 1
fi

echo "[win11-iso] converting UUPs -> ISO (wim) ..."
cd "${CONV}"
./convert.sh wim "${UUPs}" 0

echo "[win11-iso] done. ISO under ${CONV}/ or ${OUT}/"
ls -lh "${CONV}"/*.ISO "${OUT}"/*.ISO 2>/dev/null || ls -lh "${CONV}" | tail
