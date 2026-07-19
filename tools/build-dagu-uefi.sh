#!/usr/bin/env bash
# Build boot-dagu.img — WSL native ext4 only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/wsl-workspace-lib.sh"

if [[ "${PWD}" == /mnt/* ]]; then
  echo "[build-dagu] ERROR: 禁止在 /mnt 下编译。" >&2
  echo "[build-dagu] cd ${WSL_WORKSPACE} && ./tools/build-dagu-uefi.sh" >&2
  exit 1
fi

ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EDK2="${ROOT}/edk2-msm"
OUT="${ROOT}/artifacts"

if [[ ! -f "${ROOT}/.wsl-workspace" ]]; then
  echo "[build-dagu] ERROR: 请先 bootstrap WSL 工作区。" >&2
  exit 1
fi

if [[ ! -d "${EDK2}/.git" ]]; then
  echo "[build-dagu] edk2-msm missing. Run tools/bootstrap-wsl-workspace.sh" >&2
  exit 1
fi

cd "${EDK2}"
mkdir -p "${OUT}"

export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
_SIMPLE_INIT="${EDK2}/GPLDrivers/Library/SimpleInit"
if [[ ! -f "${_SIMPLE_INIT}/build/rootfs.c" ]] || [[ ! -f "${_SIMPLE_INIT}/build/rootfs_data.o" ]]; then
  echo "[build-dagu] generating SimpleInit rootfs ..."
  bash "${_SIMPLE_INIT}/scripts/gen-rootfs-source.sh" "${_SIMPLE_INIT}" "${_SIMPLE_INIT}/build"
fi

BUILD_ARGS=()
UART_ENABLED=0
for arg in "$@"; do
  if [[ "${arg}" == "--no-uart" ]]; then
    UART_ENABLED=0
    continue
  fi
  if [[ "${arg}" == "--uart" ]] || [[ "${arg}" == "-u" ]]; then
    UART_ENABLED=1
    continue
  fi
  BUILD_ARGS+=("${arg}")
done

if [[ "${UART_ENABLED}" -eq 1 ]]; then
  BUILD_ARGS=(-u "${BUILD_ARGS[@]}")
  echo "[build-dagu] USE_UART=1 (hardware UART; default is on-screen FB console)"
else
  echo "[build-dagu] USE_UART=0 (FrameBufferSerialPortLib — boot text on screen)"
fi

if [[ ! -f "${ROOT}/port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabFatDisk.bin" ]]; then
  echo "[build-dagu] generating empty TestLab FAT template ..."
  bash "${ROOT}/tools/gen-testlab-fat-empty.sh"
fi

echo "[build-dagu] applying dagu port overlay ..."
bash "${ROOT}/tools/apply-dagu-port.sh"

echo "[build-dagu] workspace: ${ROOT}"
./build.sh -d dagu --skip-rootfs-gen "${BUILD_ARGS[@]}"

IMG=$(find "${EDK2}" -path "*/boot-dagu.img" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
[[ -z "${IMG}" ]] && IMG="${EDK2}/boot-dagu.img"
[[ ! -f "${IMG}" ]] && echo "boot-dagu.img not found" >&2 && exit 1

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="${OUT}/boot-dagu-${STAMP}.img"
cp -v "${IMG}" "${DEST}"
rm -f "${OUT}/boot-dagu-latest.img"
cp -fv "${DEST}" "${OUT}/boot-dagu-latest.img"
echo "[build-dagu] OK -> ${DEST}"

# WSL 编译在 ext4；Windows fastboot 读 E:\...\artifacts，必须回拷最新镜像。
publish_boot_artifact_to_win "${OUT}/boot-dagu-latest.img"
