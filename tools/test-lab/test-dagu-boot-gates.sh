#!/usr/bin/env bash
# Static + artifact gates — run after apply-dagu-port / build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1 — $2"; FAIL=$((FAIL + 1)); }

need_grep() {
  local file="$1" pat="$2" name="$3"
  if [[ ! -f "${file}" ]]; then fail "${name}" "missing ${file}"; return; fi
  if grep -qE "${pat}" "${file}"; then pass "${name}"; else fail "${name}" "pattern ${pat}"; fi
}
forbid_grep() {
  local file="$1" pat="$2" name="$3"
  if [[ ! -f "${file}" ]]; then fail "${name}" "missing ${file}"; return; fi
  if grep -qE "${pat}" "${file}"; then fail "${name}" "forbidden ${pat}"; else pass "${name}"; fi
}

echo "=== dagu boot gates (repo=${ROOT}) ==="

BM="${ROOT}/port/dagu/Common/edk2/MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenu.c"
PBM="${ROOT}/port/dagu/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c"
DSC="${ROOT}/port/dagu/Platform/Xiaomi/sm8250/dagu.dsc"
FDF="${ROOT}/port/dagu/Platform/Xiaomi/sm8250/dagu.fdf.inc"

need_grep "${PBM}" "PlatformDaguEnterInteractiveBootMenu" "A1 interactive menu loop"
forbid_grep "${PBM}" "EfiBootManagerRefreshAllBootOption\\s*\\(" "A2 no RefreshAll"
need_grep "${PBM}" "PlatformDaguPruneNonFirmwareBootOptions" "A3 prune Misc Devices"
forbid_grep "${PBM}" "USB Mass Storage" "A4 no Mass Storage option"
forbid_grep "${PBM}" "ENABLE_LINUX_SIMPLE_MASS_STORAGE" "A4b LSMS compile path gone"
need_grep "${BM}" "DaguReadAnyKey" "B1 multi-ConIn poll"
need_grep "${BM}" "SCAN_VOLUME_UP" "B2 volume up"
need_grep "${BM}" "SCAN_SUSPEND" "B3 power confirm"
forbid_grep "${BM}" "WaitForEvent \\(1, &gST->ConIn->WaitForKey" "B4 no ConIn-only wait"
forbid_grep "${BM}" "EfiBootManagerRefreshAllBootOption\\s*\\(" "B6 no menu RefreshAll"
need_grep "${BM}" "MEDIA_PIWG_FW_FILE_DP" "B7 FV-only menu filter"
need_grep "${DSC}" "ENABLE_SIMPLE_INIT" "C1 simple init flag"
forbid_grep "${DSC}" "ENABLE_LINUX_SIMPLE_MASS_STORAGE" "C1b LSMS flag removed"
need_grep "${DSC}" "0xdc, 0x5b, 0xc2, 0xee" "C2 BootManagerMenuApp PCD"
need_grep "${FDF}" "BootManagerMenuApp.inf" "C3 BootManagerMenuApp in FDF"
forbid_grep "${ROOT}/port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabBridgeDxe.c" \
  "gLinuxSimpleMassStorageGuid|TestLabPublishUsbMassStorage" "C4 no TestLab LSMS start"
forbid_grep "${ROOT}/port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabBridgeDxe.inf" \
  "gLinuxSimpleMassStorageGuid" "C4b TestLab INF has no LSMS GUID"
if [[ -e "${ROOT}/tools/lsms/build-lsms.sh" ]]; then
  fail "C4c LSMS tooling gone" "tools/lsms/build-lsms.sh still present"
else
  pass "C4c LSMS tooling gone"
fi
need_grep "${ROOT}/tools/apply-dagu-port.sh" "strip LinuxSimpleMassStorage" "C4d apply strips stock LSMS"

if [[ -f "${ROOT}/artifacts/boot-dagu-latest.img" && -f "${ROOT}/artifacts/boot-dagu-latest.stamp" ]]; then
  bash "${ROOT}/tools/verify-boot-artifact.sh" "${ROOT}/artifacts/boot-dagu-latest.img" \
    && pass "E1 verify-boot-artifact" || fail "E1 verify-boot-artifact" "verify failed"
fi

echo "=== summary: ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
