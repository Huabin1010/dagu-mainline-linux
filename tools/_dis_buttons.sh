#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EFI="${ROOT}/edk2-msm/Platform/EFI_Binaries/Drivers/Devices/elish/ButtonsDxe/ButtonsDxe.efi"
OUT=/tmp/buttons.dis
llvm-objdump -d --section=.text "$EFI" > "$OUT"
wc -l "$OUT"

python3 <<PY
from pathlib import Path
b = Path("${ROOT}/edk2-msm/Platform/EFI_Binaries/Drivers/Devices/elish/ButtonsDxe/ButtonsDxe.efi").read_bytes()
needles = [
    b"Failed to locate PlatformInfo",
    b"failed to locate PmicGpio",
    b"failed to locate PmicPON",
    b"InitializeKeyMap",
    b"ConfigureButtonGPIOs",
    b"failed for home button",
    b"failed for VOL+ button",
]
for n in needles:
    off = b.find(n)
    print(n.decode("ascii", "ignore")[:40], "file", hex(off), "VA", hex(off))
PY

# Show call sites near ButtonsInit by searching for mov/adrp patterns referencing page 0x6000
grep -n "adrp\|adr " "$OUT" | grep -E "0x6[0-9a-f]{3}|0x7[0-9a-f]{3}|0x8[0-9a-f]{3}" | head -40
