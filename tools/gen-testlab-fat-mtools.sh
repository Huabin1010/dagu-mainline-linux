#!/usr/bin/env bash
# Generate TestLab FAT via mkfs.vfat + mtools (no mount/sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabFatDisk.bin"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

command -v mkfs.vfat >/dev/null
command -v mcopy >/dev/null || { echo "install mtools"; exit 1; }

dd if=/dev/zero of="${OUT}" bs=8M count=1 status=none
mkfs.vfat -F 32 -n TESTLAB "${OUT}"
mmd -i "${OUT}" ::TESTLAB
: > "${TMP}/BOOT.LOG"
echo 0 > "${TMP}/BOOT.SEQ"
: > "${TMP}/COMMAND.IN"
echo OK > "${TMP}/COMMAND.ACK"
echo '{"seq":0,"usb":"pending","bridge":"v2"}' > "${TMP}/STATUS.JSON"
mcopy -i "${OUT}" "${TMP}/BOOT.LOG" ::TESTLAB/BOOT.LOG
mcopy -i "${OUT}" "${TMP}/BOOT.SEQ" ::TESTLAB/BOOT.SEQ
mcopy -i "${OUT}" "${TMP}/COMMAND.IN" ::TESTLAB/COMMAND.IN
mcopy -i "${OUT}" "${TMP}/COMMAND.ACK" ::TESTLAB/COMMAND.ACK
mcopy -i "${OUT}" "${TMP}/STATUS.JSON" ::TESTLAB/STATUS.JSON
echo "[gen-testlab-fat-mtools] OK -> ${OUT} ($(stat -c%s "${OUT}") bytes)"
