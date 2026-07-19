#!/usr/bin/env bash
# Download dagu stock fastboot ROM (once) and extract vendor_boot DTB for edk2-msm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FW_DIR="${ROOT}/vendor/firmware"
ROM="${FW_DIR}/dagu_images_OS2.0.10.0.ULZCNXM.tgz"
ROM_URL="${DAGU_ROM_URL:-https://bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com/OS2.0.10.0.ULZCNXM/dagu_images_OS2.0.10.0.ULZCNXM_20250701.0000.00_14.0_cn_8b79098f43.tgz}"
VENDOR_BOOT="${FW_DIR}/vendor_boot.img"

usage() {
  cat <<EOF
Usage: fetch-dagu-stock-dtb.sh [--skip-download]

Downloads stock HyperOS fastboot ROM (~5.5GB, cached under vendor/firmware/)
and extracts dagu.dtb from vendor_boot.img into port/dagu/.../FdtBlob_compat/.

Environment:
  DAGU_ROM_URL   Override ROM .tgz URL
  DAGU_ROM_PATH  Use an existing extracted ROM directory (contains images/vendor_boot.img)
EOF
}

skip_download=0
[[ "${1:-}" == "--skip-download" ]] && skip_download=1

mkdir -p "${FW_DIR}"

if [[ -n "${DAGU_ROM_PATH:-}" ]]; then
  VENDOR_BOOT="${DAGU_ROM_PATH}/images/vendor_boot.img"
elif [[ ! -f "${VENDOR_BOOT}" ]]; then
  if [[ ! -f "${ROM}" ]]; then
    if [[ "${skip_download}" -eq 1 ]]; then
      echo "[fetch-dagu-stock-dtb] missing ${ROM}; run without --skip-download" >&2
      exit 1
    fi
    echo "[fetch-dagu-stock-dtb] downloading stock ROM (~5.5GB) ..."
    echo "[fetch-dagu-stock-dtb] URL: ${ROM_URL}"
    curl -fL --retry 3 -C - -o "${ROM}" "${ROM_URL}"
  fi
  echo "[fetch-dagu-stock-dtb] extracting images/vendor_boot.img ..."
  rm -rf "${FW_DIR}/rom-tree"
  mkdir -p "${FW_DIR}/rom-tree"
  tar -xzf "${ROM}" -C "${FW_DIR}/rom-tree"
  found="$(find "${FW_DIR}/rom-tree" -path '*/images/vendor_boot.img' -type f | head -1 || true)"
  if [[ -z "${found}" ]]; then
    echo "[fetch-dagu-stock-dtb] ERROR: vendor_boot.img not found inside ${ROM}" >&2
    exit 1
  fi
  cp -f "${found}" "${VENDOR_BOOT}"
fi

DTBO="${FW_DIR}/dtbo.img"
if [[ -n "${DAGU_ROM_PATH:-}" ]]; then
  DTBO="${DAGU_ROM_PATH}/images/dtbo.img"
elif [[ ! -f "${DTBO}" ]]; then
  found_dtbo="$(find "${FW_DIR}/rom-tree" -path '*/images/dtbo.img' -type f | head -1 || true)"
  [[ -n "${found_dtbo}" ]] && cp -f "${found_dtbo}" "${DTBO}"
fi

if [[ ! -f "${DTBO}" ]]; then
  echo "[fetch-dagu-stock-dtb] ERROR: dtbo.img not found" >&2
  exit 1
fi

bash "${SCRIPT_DIR}/extract-dagu-dtb.sh" "${VENDOR_BOOT}" "${DTBO}"
echo "[fetch-dagu-stock-dtb] done"
