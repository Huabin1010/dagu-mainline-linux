#!/usr/bin/env bash
# Generate TestLab FAT32 disk image (1 MiB, volume label TESTLAB) for v2 protocol.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_BIN="${ROOT}/port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabFatDisk.bin"

mkdir -p "$(dirname "${OUT_BIN}")"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

dd if=/dev/zero of="${OUT_BIN}" bs=1M count=8 status=none
mkfs.vfat -F 32 -n TESTLAB "${OUT_BIN}"
MNT="${WORK}/mnt"
mkdir -p "${MNT}"
sudo mount -o loop "${OUT_BIN}" "${MNT}"
mkdir -p "${MNT}/TESTLAB"
: > "${MNT}/TESTLAB/BOOT.LOG"
echo 0 > "${MNT}/TESTLAB/BOOT.SEQ"
: > "${MNT}/TESTLAB/COMMAND.IN"
echo OK > "${MNT}/TESTLAB/COMMAND.ACK"
echo '{"seq":0,"usb":"pending","bridge":"v2"}' > "${MNT}/TESTLAB/STATUS.JSON"
sync
sudo umount "${MNT}"

echo "[gen-testlab-fat] OK -> ${OUT_BIN} ($(stat -c%s "${OUT_BIN}") bytes)"
