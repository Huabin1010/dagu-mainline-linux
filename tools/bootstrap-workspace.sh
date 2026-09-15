#!/usr/bin/env bash
# Clone edk2-msm + vendor into this repo (not tracked in git).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

EDK2_URL="${EDK2_URL:-https://github.com/edk2-porting/edk2-msm.git}"
VENDOR_DT_URL="${VENDOR_DT_URL:-https://github.com/MiCode/kernel_devicetree.git}"
VENDOR_DT_BRANCH="${VENDOR_DT_BRANCH:-dagu-s-oss}"

cd "${ROOT}"

if [[ ! -d edk2-msm/.git ]]; then
  echo "[bootstrap] git clone --recursive ${EDK2_URL}"
  git clone --recursive "${EDK2_URL}" edk2-msm
else
  git -C edk2-msm pull --ff-only || true
  git -C edk2-msm submodule update --init --recursive
fi

if [[ ! -d vendor/kernel_devicetree/.git ]]; then
  mkdir -p vendor
  echo "[bootstrap] git clone -b ${VENDOR_DT_BRANCH} ${VENDOR_DT_URL}"
  git clone -b "${VENDOR_DT_BRANCH}" "${VENDOR_DT_URL}" vendor/kernel_devicetree
else
  git -C vendor/kernel_devicetree pull --ff-only || true
fi

mkdir -p artifacts dumps
bash tools/apply-dagu-port.sh

echo "[bootstrap] OK: ${ROOT}"
echo "  ./tools/build-dagu-uefi.sh"
