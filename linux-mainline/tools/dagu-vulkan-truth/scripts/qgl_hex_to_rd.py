#!/usr/bin/env python3
"""Turn QGL pm4dumpenable hex logs into a Freedreno .rd for cffdump."""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

RD_GPUADDR, RD_CMDSTREAM_ADDR, RD_BUFFER_CONTENTS, RD_GPU_ID = 3, 6, 12, 13


def write_sect(f, typ, payload: bytes):
    f.write(struct.pack("<II", typ, len(payload)))
    f.write(payload)


def parse_hex(path: Path) -> tuple[int | None, list[int]]:
    gpu = None
    words = []
    for line in path.read_text().splitlines():
        s = line.strip()
        if s.startswith("//") and "GPUADDR" in s:
            hx = s.split()[-1]
            try:
                gpu = int(hx, 16)
            except ValueError:
                pass
            continue
        if len(s) == 8 and all(c in "0123456789abcdefABCDEF" for c in s):
            words.append(int(s, 16))
    return gpu, words


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logs", nargs="+", type=Path)
    ap.add_argument("-o", "--out", type=Path, required=True)
    args = ap.parse_args()
    with args.out.open("wb") as f:
        write_sect(f, RD_GPU_ID, struct.pack("<I", 650))
        for i, log in enumerate(args.logs):
            gpu, words = parse_hex(log)
            if not words:
                continue
            blob = struct.pack("<%dI" % len(words), *words)
            if gpu is None:
                gpu = 0x50000000 + i * 0x100000
            write_sect(f, RD_GPUADDR, struct.pack("<III", gpu & 0xFFFFFFFF, len(blob), gpu >> 32))
            write_sect(f, RD_BUFFER_CONTENTS, blob)
            write_sect(f, RD_CMDSTREAM_ADDR, struct.pack("<III", gpu & 0xFFFFFFFF, len(words), gpu >> 32))
            print(f"  {log.name}: gpu=0x{gpu:x} words={len(words)}")
    print(f"wrote {args.out} ({args.out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
