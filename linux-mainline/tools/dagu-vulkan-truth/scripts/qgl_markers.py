#!/usr/bin/env python3
"""Scan QGL hex IB logs for CP_SET_MARKER / CP_BLIT / A2D dest info."""
from __future__ import annotations

import sys
from pathlib import Path

MARK = {
    1: "RM6_DIRECT_RENDER",
    2: "RM6_BIN_VISIBILITY",
    3: "RM6_BIN_DIRECT",
    4: "RM6_BIN_RENDER_START",
    5: "RM6_BIN_END_OF_DRAWS",
    6: "RM6_BIN_RESOLVE",
    7: "RM6_BIN_RENDER_END",
    8: "RM6_COMPUTE",
    12: "RM6_BLIT2DSCALE",
}

def words(path: Path):
    out = []
    for line in path.read_text().splitlines():
        s = line.strip()
        if len(s) == 8 and all(c in "0123456789abcdefABCDEF" for c in s):
            out.append(int(s, 16))
    return out

def pkt7(w):
    return (w & 0xF0000000) == 0x70000000

def pkt4(w):
    return (w & 0xF0000000) == 0x40000000

def main():
    for p in map(Path, sys.argv[1:]):
        ws = words(p)
        print(f"==== {p.name} words={len(ws)} ====")
        i = 0
        while i < len(ws):
            w = ws[i]
            if pkt7(w):
                op, cnt = (w >> 16) & 0x7F, w & 0x3FFF
                body = ws[i + 1 : i + 1 + cnt]
                if op == 0x65:
                    m = body[0] if body else -1
                    print(f"  CP_SET_MARKER {m} {MARK.get(m & 0xF, '')} raw=0x{m:x}")
                elif op == 0x2C:
                    print(f"  CP_BLIT op={body[0] if body else None}")
                elif op == 0x46:
                    print(f"  CP_EVENT_WRITE ev=0x{body[0]:x}" if body else "  CP_EVENT_WRITE")
                i += 1 + cnt
                continue
            if pkt4(w):
                reg, cnt = (w >> 8) & 0x3FFFF, w & 0x7F
                vals = ws[i + 1 : i + 1 + cnt]
                if reg == 0x8C17 and vals:
                    v = vals[0]
                    fmt, tile = v & 0xFF, (v >> 8) & 3
                    print(f"  RB_A2D_DEST_BUFFER_INFO 0x{v:08x} fmt=0x{fmt:x} tile={tile}")
                elif reg == 0x8C1A and vals:
                    print(f"  RB_A2D_DEST_BUFFER_PITCH raw={vals[0]} bytes={vals[0]*64}")
                elif reg == 0x8C00 and vals:
                    print(f"  RB_A2D_BLT_CNTL 0x{vals[0]:08x}")
                i += 1 + cnt
                continue
            i += 1

if __name__ == "__main__":
    main()
