#!/usr/bin/env bash
# Generate empty 1 MiB FAT32 template (files created by firmware at runtime).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabFatDisk.bin"
mkdir -p "$(dirname "${OUT}")"
dd if=/dev/zero of="${OUT}" bs=1M count=1 status=none
mkfs.vfat -F 32 -n TESTLAB "${OUT}"
echo "[gen-testlab-fat-empty] OK -> ${OUT} ($(stat -c%s "${OUT}") bytes)"
