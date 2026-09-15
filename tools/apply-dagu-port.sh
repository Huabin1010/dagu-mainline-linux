#!/usr/bin/env bash
# Apply tracked dagu port overlay into a fresh edk2-msm clone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PORT="${ROOT}/port/dagu"
EDK2="${ROOT}/edk2-msm"

if [[ ! -d "${EDK2}/.git" ]]; then
  echo "[apply-dagu-port] edk2-msm not found. Run tools/bootstrap-workspace.sh first." >&2
  exit 1
fi

if [[ ! -d "${PORT}" ]]; then
  echo "[apply-dagu-port] missing ${PORT}" >&2
  exit 1
fi

echo "[apply-dagu-port] overlay -> ${EDK2}"
rsync -a "${PORT}/" "${EDK2}/"

GUID_H="${PORT}/Silicon/Qualcomm/QcomPkg/Include/Guid/TestLabBridgeGuid.h"
TESTLAB_ON=0
if [[ -f "${GUID_H}" ]] && grep -qE '#define[[:space:]]+TESTLAB_ENABLE_BRIDGE[[:space:]]+1' "${GUID_H}"; then
  TESTLAB_ON=1
fi

DAGU_DSC="${EDK2}/Platform/Xiaomi/sm8250/dagu.dsc"
USE_ROTATION_FB=0
if [[ -f "${DAGU_DSC}" ]] && grep -q 'PcdMipiFrameBufferRotation' "${DAGU_DSC}"; then
  USE_ROTATION_FB=1
fi

if [[ "${TESTLAB_ON}" -eq 0 ]]; then
  echo "[apply-dagu-port] TestLab disabled (TESTLAB_ENABLE_BRIDGE=0)"
  for f in "${DAGU_DSC}" "${EDK2}/Platform/Xiaomi/sm8250/dagu.fdf.inc"; do
    [[ -f "${f}" ]] && sed -i '/TestLabBridgeDxe/d' "${f}"
  done
fi

# Do not ship LinuxSimpleMassStorage in the dagu FV (MSC path abandoned).
echo "[apply-dagu-port] strip LinuxSimpleMassStorage from sm8250 FDF/DSC"
for f in \
  "${EDK2}/Platform/Qualcomm/sm8250/sm8250.fdf" \
  "${EDK2}/Platform/Qualcomm/sm8250/sm8250.dsc" \
  "${EDK2}/Silicon/Qualcomm/QcomPkg/QcomCommonDsc.inc"
do
  if [[ -f "${f}" ]] && grep -q 'LinuxSimpleMassStorage' "${f}"; then
    sed -i '/LinuxSimpleMassStorage/d' "${f}"
  fi
done

if [[ "${USE_ROTATION_FB}" -eq 0 ]]; then
  echo "[apply-dagu-port] portrait FB — stock GraphicsConsole"
  git -C "${EDK2}" checkout HEAD -- \
    Common/edk2/MdeModulePkg/Universal/Console/GraphicsConsoleDxe/GraphicsConsole.c 2>/dev/null || true
else
  echo "[apply-dagu-port] landscape rotate+150% — port SimpleFbDxe + dagu text mode"
fi

DEC="${EDK2}/Silicon/Qualcomm/QcomPkg/QcomPkg.dec"
if [[ -f "${DEC}" ]] && ! grep -q 'PcdMipiFrameBufferRotation' "${DEC}"; then
  echo "[apply-dagu-port] add PcdMipiFrameBufferRotation to QcomPkg.dec"
  sed -i '/PcdMipiFrameBufferDelay/a\  gQcomTokenSpaceGuid.PcdMipiFrameBufferRotation|0|UINT32|0x0000a407' "${DEC}"
fi
if [[ -f "${DEC}" ]] && ! grep -q 'PcdMipiFrameBufferConsoleScale' "${DEC}"; then
  echo "[apply-dagu-port] add PcdMipiFrameBufferConsoleScale to QcomPkg.dec"
  sed -i '/PcdMipiFrameBufferRotation/a\  gQcomTokenSpaceGuid.PcdMipiFrameBufferConsoleScale|100|UINT32|0x0000a408' "${DEC}"
fi
if [[ -f "${DEC}" ]] && ! grep -q 'gTestLabBridgeProtocolGuid' "${DEC}"; then
  echo "[apply-dagu-port] add TestLab bridge GUIDs to QcomPkg.dec"
  sed -i '/\[Guids\]/a\  gTestLabBridgeProtocolGuid = { 0x7c9f2a11, 0x4b6e, 0x4d2a, { 0x9e, 0x31, 0x44, 0x8d, 0x20, 0x11, 0xab, 0x7f } }\n  gTestLabBridgeRamDiskGuid  = { 0x8d0e3b22, 0x5c4f, 0x4a8e, { 0xbf, 0x12, 0x55, 0x6c, 0x90, 0x21, 0x3e, 0x44 } }' "${DEC}"
elif [[ -f "${DEC}" ]] && ! grep -q 'gTestLabBridgeRamDiskGuid' "${DEC}"; then
  echo "[apply-dagu-port] add TestLab ramdisk GUID to QcomPkg.dec"
  sed -i '/gTestLabBridgeProtocolGuid/a\  gTestLabBridgeRamDiskGuid  = { 0x8d0e3b22, 0x5c4f, 0x4a8e, { 0xbf, 0x12, 0x55, 0x6c, 0x90, 0x21, 0x3e, 0x44 } }' "${DEC}"
fi

GC="${EDK2}/Common/edk2/MdeModulePkg/Universal/Console/GraphicsConsoleDxe/GraphicsConsole.c"
if [[ "${USE_ROTATION_FB}" -eq 1 ]] && [[ -f "${GC}" ]]; then
  if grep -q '{ 248, 64 }' "${GC}"; then
    echo "[apply-dagu-port] update dagu text mode 248x64 -> 206x53"
    sed -i 's/{ 248, 64 },.*dagu/{ 206, 53 },  \/\/ 1706x1066 logical, 150% upscale (dagu)/' "${GC}"
  elif grep -q '{ 310, 80 }' "${GC}"; then
    echo "[apply-dagu-port] update dagu text mode 310x80 -> 206x53"
    sed -i 's/{ 310, 80 },.*dagu/{ 206, 53 },  \/\/ 1706x1066 logical, 150% upscale (dagu)/' "${GC}"
  elif ! grep -q '{ 206, 53 }' "${GC}"; then
    echo "[apply-dagu-port] add dagu scaled full-screen text mode to GraphicsConsole.c"
    sed -i '/{ 240, 56 }.*1920 x 1080/a\  { 206, 53 },  \/\/ 1706x1066 logical, 150% upscale (dagu)' "${GC}"
  fi
  # Fix accidental extra paren from older sed
  sed -i 's/(dagu)))/(dagu)/' "${GC}"
fi

FDF="${EDK2}/Platform/Qualcomm/sm8250/sm8250.fdf"
if [[ -f "${FDF}" ]] && grep -q 'TestLabBridgeDxe.inf' "${FDF}"; then
  echo "[apply-dagu-port] remove early TestLabBridgeDxe from sm8250.fdf (now in dagu.fdf.inc)"
  sed -i '/TestLabBridgeDxe\/TestLabBridgeDxe.inf/d' "${FDF}"
fi

FB_SER="${EDK2}/Silicon/Qualcomm/QcomPkg/Library/FrameBufferSerialPortLib/FrameBufferSerialPortLib.c"
if [[ -f "${FB_SER}" ]]; then
  echo "[apply-dagu-port] FrameBufferSerialPortLib overlay from port (red splash)"
fi

BM="${EDK2}/Common/edk2/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenu.c"
if [[ -f "${BM}" ]]; then
  if grep -q 'DaguReadAnyKey' "${BM}"; then
    echo "[apply-dagu-port] BootManagerMenu: multi-ConIn + volume/power (from port overlay)"
  else
    echo "[apply-dagu-port] BootManagerMenu: applying multi-ConIn patch"
    python3 "${ROOT}/tools/patch-boot-manager-menu.py" "${BM}"
  fi
fi

# Build dagu-patched ButtonsDxe (skip HOME GPIO abort) from elish binary.
BTN_DIR="${EDK2}/Platform/EFI_Binaries/Drivers/Devices/elish/ButtonsDxe"
if [[ -f "${ROOT}/tools/patch-buttons-skip-home.py" && -f "${BTN_DIR}/ButtonsDxe.efi" ]]; then
  echo "[apply-dagu-port] patching ButtonsDxe HOME-skip -> ButtonsDxe.dagu.efi"
  python3 "${ROOT}/tools/patch-buttons-skip-home.py"
fi

# Apriori loads ButtonsDxe by GUID from its own PE32 path — must be the dagu
# patched elish binary (HOME-skip). Generic sm8250 is phone layout; stock elish
# still aborts on missing HOME.
APRIORI="${EDK2}/Platform/Qualcomm/sm8250/Apriori.fdf.inc"
DAGU_BTN="Platform/EFI_Binaries/Drivers/Devices/elish/ButtonsDxe/ButtonsDxe.dagu.efi"
if [[ -f "${APRIORI}" ]]; then
  if grep -q 'ButtonsDxe.dagu.efi' "${APRIORI}"; then
    echo "[apply-dagu-port] Apriori ButtonsDxe already dagu-patched"
  else
    echo "[apply-dagu-port] Apriori ButtonsDxe -> Devices/elish ButtonsDxe.dagu.efi"
    sed -i \
      -e 's|Platform/EFI_Binaries/Drivers/sm8250/ButtonsDxe/ButtonsDxe\.efi|'"${DAGU_BTN}"'|g' \
      -e 's|Platform/EFI_Binaries/Drivers/Devices/elish/ButtonsDxe/ButtonsDxe\.efi|'"${DAGU_BTN}"'|g' \
      "${APRIORI}"
    if ! grep -q 'ButtonsDxe.dagu.efi' "${APRIORI}"; then
      echo "[apply-dagu-port] WARN: Apriori ButtonsDxe path unexpected" >&2
    fi
  fi
fi

if [[ ! -f "${BTN_DIR}/ButtonsDxe.dagu.efi" ]]; then
  echo "[apply-dagu-port] ERROR: ${BTN_DIR}/ButtonsDxe.dagu.efi missing" >&2
  exit 1
fi

echo "[apply-dagu-port] OK"
