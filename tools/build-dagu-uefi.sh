#!/usr/bin/env bash
# Build boot-dagu.img in this Linux workspace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EDK2="${ROOT}/edk2-msm"
OUT="${ROOT}/artifacts"

write_boot_artifact_stamp() {
  local src_img="$1"
  local bytes sha256 stamp_file
  bytes="$(stat -c%s "${src_img}" 2>/dev/null || wc -c < "${src_img}")"
  if [[ "${bytes}" -lt 1048576 ]]; then
    echo "[build-dagu] refuse to stamp tiny image (${bytes} bytes): ${src_img}" >&2
    return 1
  fi
  sha256="$(sha256sum "${src_img}" | awk '{print $1}')"
  stamp_file="${src_img%.img}.stamp"
  {
    echo "source=${src_img}"
    echo "bytes=${bytes}"
    echo "sha256=${sha256}"
    echo "published_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${stamp_file}"
}

if [[ ! -d "${EDK2}/.git" ]]; then
  echo "[build-dagu] edk2-msm missing. Run tools/bootstrap-workspace.sh" >&2
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

# Force relink boot-manager changes (PlatformBm / BootManagerMenu).
echo "[build-dagu] touch boot-manager sources ..."
touch "${EDK2}/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c" 2>/dev/null || true
touch "${EDK2}/Common/edk2/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenu.c" 2>/dev/null || true

echo "[build-dagu] workspace: ${ROOT}"
if ! ./build.sh -d dagu --skip-rootfs-gen "${BUILD_ARGS[@]}"; then
  echo "[build-dagu] ERROR: edk2-msm build failed" >&2
  exit 1
fi

IMG=$(find "${EDK2}" -path "*/boot-dagu.img" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
[[ -z "${IMG}" ]] && IMG="${EDK2}/boot-dagu.img"
[[ ! -f "${IMG}" ]] && echo "[build-dagu] boot-dagu.img not found" >&2 && exit 1

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="${OUT}/boot-dagu-${STAMP}.img"
cp -v "${IMG}" "${DEST}"
rm -f "${OUT}/boot-dagu-latest.img"
cp -fv "${DEST}" "${OUT}/boot-dagu-latest.img"
echo "[build-dagu] OK -> ${DEST}"

if ! write_boot_artifact_stamp "${OUT}/boot-dagu-latest.img"; then
  echo "[build-dagu] ERROR: failed to write artifact stamp" >&2
  exit 1
fi

if ! bash "${ROOT}/tools/verify-boot-artifact.sh" "${OUT}/boot-dagu-latest.img"; then
  echo "[build-dagu] ERROR: artifact verification failed" >&2
  exit 1
fi

echo "[build-dagu] verified"
