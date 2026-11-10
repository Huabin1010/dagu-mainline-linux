"""Make qcwlan6800sc81.sys emit DbgPrintEx before its registry read.

The print function loads GlobalDebugLogOutput. That word lives in the
uninitialized section and is 0 until NdisReadConfiguration stores 1.
Zero selects the spare sink, whose mask is also 0, so the line is
discarded. The registry store happens only after the adapter
configuration opens, which is the step that currently does not finish.
The one branch into the spare sink is replaced with a no-operation, so
a line that already passed the level and component checks reaches
DbgPrintEx from the first call.

The image also stores a level of 4 and a component mask of 0x3d000986.
Messages at level 4 or above, and messages whose component bit is clear,
never reach the print function. Both initialized copies are raised to
the same values the registry already requests (level 0xff, mask
0xffffffff) so they apply before the adapter configuration opens. The
mask is a debug bitmap: each set bit is stored into a byte array and
does not program the radio.
"""

from __future__ import annotations

import struct

# adrp / ldr / cmp w8, #1 / b.ne spare-sink, at file offset 0x7370.
SINK_BRANCH = bytes.fromhex("a814009008c148b91f05007181010054")
BRANCH_AT = 12
NOP = bytes.fromhex("1f2003d5")

# Initialized copies of the debug level and the component mask. The
# registry writes the same values, but only after the adapter
# configuration opens. Unload currently happens before that open.
LEVEL_OFFS = (0x282448, 0x282450)
COMP_OFFS = (0x28244C, 0x282454)
LEVEL_STOCK = (4).to_bytes(4, "little")
COMP_STOCK = (0x3D000986).to_bytes(4, "little")
LEVEL_VERBOSE = (0xFF).to_bytes(4, "little")
COMP_VERBOSE = (0xFFFFFFFF).to_bytes(4, "little")


def pe_checksum(data: bytes) -> int:
    e = int.from_bytes(data[0x3C:0x40], "little")
    skip = e + 24 + 64
    size = len(data)
    padded = data + (b"\x00" * ((4 - size % 4) % 4))
    acc = 0
    for i in range(0, len(padded), 4):
        if i == skip:
            continue
        dword = int.from_bytes(padded[i : i + 4], "little")
        acc += dword
        acc = (acc & 0xFFFFFFFF) + (acc >> 32)
    acc = (acc & 0xFFFF) + (acc >> 16)
    acc = (acc & 0xFFFF) + (acc >> 16)
    return (acc + size) & 0xFFFFFFFF


def checksum_offset(data: bytes) -> int:
    e = int.from_bytes(data[0x3C:0x40], "little")
    return e + 24 + 64


def patch(data: bytes) -> bytes:
    found = []
    start = 0
    while True:
        i = data.find(SINK_BRANCH, start)
        if i < 0:
            break
        found.append(i)
        start = i + 1
    if found != [0x7370]:
        raise ValueError(f"debug sink branch not unique: {found}")
    out = bytearray(data)
    at = found[0] + BRANCH_AT
    if out[at : at + 4] != SINK_BRANCH[BRANCH_AT:]:
        raise ValueError("branch bytes moved")
    out[at : at + 4] = NOP
    for off in LEVEL_OFFS:
        if out[off : off + 4] != LEVEL_STOCK:
            raise ValueError(f"debug level at {off:#x} is not 4")
        out[off : off + 4] = LEVEL_VERBOSE
    for off in COMP_OFFS:
        if out[off : off + 4] != COMP_STOCK:
            raise ValueError(f"component mask at {off:#x} is not the stock value")
        out[off : off + 4] = COMP_VERBOSE
    csum = pe_checksum(bytes(out))
    off = checksum_offset(bytes(out))
    out[off : off + 4] = struct.pack("<I", csum)
    if pe_checksum(bytes(out)) != csum:
        raise ValueError("checksum did not stick")
    return bytes(out)
