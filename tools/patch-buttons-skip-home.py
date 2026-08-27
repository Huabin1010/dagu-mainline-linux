#!/usr/bin/env python3
"""
Patch elish ButtonsDxe for dagu (Pad 5 Pro 12.4) — V4.

Confirmed by disassembly of InitializeKeyMap (0x3748):

  GetPlatformInfo() → platform type
  switch(type): MTP(8)/CDP/… → copy key map (SUCCESS)
                OEM(5)/unknown → return EFI_NOT_FOUND (FAIL)

Xiaomi tablets typically report EFI_PLATFORMINFO_TYPE_OEM (5), which hits the
FAIL path. Our earlier “ignore IKM error” left the key map EMPTY, so Vol/Power
never generated scancodes even after HOME-skip.

V4 patches:
  P0 Force platform type = MTP (8) inside InitializeKeyMap
  P1 HOME EnableInput failure → return EFI_SUCCESS (still no HOME key)
  P2 ButtonsInit: ignore residual IKM error
  P3 ButtonsInit: ConfigureButtonGPIOs failure → EFI_SUCCESS
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

MOV_X19_XZR = 0xAA1F03F3  # mov x19, xzr
MOV_W9_8 = 0x52800109  # mov w9, #8


def encode_b(pc: int, target: int) -> int:
    imm26 = (target - pc) >> 2
    return 0x14000000 | (imm26 & 0x3FFFFFF)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    src = (
        root
        / "edk2-msm/Platform/EFI_Binaries/Drivers/Devices/elish/ButtonsDxe/ButtonsDxe.efi"
    )
    if not src.exists():
        print(f"missing {src}", file=sys.stderr)
        return 1
    dst = src.with_name("ButtonsDxe.dagu.efi")
    data = bytearray(src.read_bytes())

    # P0: 0x37c0 ldr w9,[sp,#8] → mov w9,#8 (MTP key map)
    insn = struct.unpack_from("<I", data, 0x37C0)[0]
    if insn != 0xB9400BE9:  # ldr w9, [sp, #8]
        print(f"unexpected insn at 0x37c0: {insn:08x} (want b9400be9)", file=sys.stderr)
        return 2
    struct.pack_into("<I", data, 0x37C0, MOV_W9_8)
    print("P0 InitializeKeyMap: force platform type MTP(8)")

    # P1: HOME fail → x19=0; b epilogue
    insn = struct.unpack_from("<I", data, 0x3A10)[0]
    if insn != 0xB6F80133:
        print(f"unexpected insn at 0x3a10: {insn:08x}", file=sys.stderr)
        return 3
    struct.pack_into("<I", data, 0x3A10, MOV_X19_XZR)
    struct.pack_into("<I", data, 0x3A14, encode_b(0x3A14, 0x3A34))
    print("P1 ConfigureButtonGPIOs: HOME fail -> EFI_SUCCESS")

    # P2: ignore IKM error in ButtonsInit
    insn = struct.unpack_from("<I", data, 0x3ACC)[0]
    if insn != 0xB7F80293:
        print(f"unexpected insn at 0x3acc: {insn:08x}", file=sys.stderr)
        return 4
    struct.pack_into("<I", data, 0x3ACC, MOV_X19_XZR)
    print("P2 ButtonsInit: InitializeKeyMap fail ignored")

    # P3: Configure fail → SUCCESS
    insn = struct.unpack_from("<I", data, 0x3AD8)[0]
    if insn != 0xB6F802D3:
        print(f"unexpected insn at 0x3ad8: {insn:08x}", file=sys.stderr)
        return 5
    struct.pack_into("<I", data, 0x3AD8, MOV_X19_XZR)
    struct.pack_into("<I", data, 0x3ADC, encode_b(0x3ADC, 0x3B30))
    print("P3 ButtonsInit: ConfigureButtonGPIOs fail -> EFI_SUCCESS")

    marker = b"DAGU-BTN-SKIP-V4"
    anchor = data.find(b"ButtonsDxe - PollButtonKeys failed")
    if anchor >= 0:
        data[anchor : anchor + len(marker)] = marker

    dst.write_bytes(data)
    print("wrote", dst, "OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
