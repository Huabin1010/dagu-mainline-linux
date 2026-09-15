#!/usr/bin/env python3
"""First-pass decoder for Freedreno .rd captures (no cffdump required).

Looks for the judgment anchors:
  CP_SET_RENDER_MODE (RM6_*), CP_BLIT, CP_EVENT_WRITE, TILE bits.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

RD_NONE, RD_TEST, RD_CMD, RD_GPUADDR, RD_CONTEXT, RD_CMDSTREAM = range(6)
RD_CMDSTREAM_ADDR, RD_PARAM, RD_FLUSH, RD_PROGRAM = 6, 7, 8, 9
RD_VERT_SHADER, RD_FRAG_SHADER, RD_BUFFER_CONTENTS, RD_GPU_ID, RD_CHIP_ID = (
    10,
    11,
    12,
    13,
    14,
)

CP_EVENT_WRITE = 0x46
CP_BLIT = 0x2C
CP_SET_RENDER_MODE = 0x6C
CP_INDIRECT_BUFFER_PFE = 0x3F
CP_INDIRECT_BUFFER_PFD = 0x37
CP_SET_DRAW_STATE = 0x43

RM6 = {
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

EVENTS = {
    0x04: "CACHE_FLUSH_TS",
    0x16: "RB_DONE_TS",
    0x18: "PC_CCU_INVALIDATE_DEPTH",
    0x19: "PC_CCU_INVALIDATE_COLOR",
    0x1A: "PC_CCU_RESOLVE_TS",
    0x1C: "PC_CCU_FLUSH_DEPTH_TS",
    0x1D: "PC_CCU_FLUSH_COLOR_TS",
    0x1E: "CCU_RESOLVE",
    0x31: "CACHE_INVALIDATE",
}

CP_DRAW_INDX = 0x22
CP_DRAW_INDX_OFFSET = 0x38
CP_DRAW_INDIRECT = 0x28
CP_DRAW_AUTO = 0x24

# a6xx type-7: 0x7 | cnt | parity<<15 | opcode<<16 | parity<<23
def pkt7_ok(w: int) -> bool:
    return (w & 0xF0000000) == 0x70000000


def pkt4_ok(w: int) -> bool:
    return (w & 0xF0000000) == 0x40000000


def pkt7_op(w: int) -> int:
    return (w >> 16) & 0x7F


def pkt7_cnt(w: int) -> int:
    return w & 0x3FFF


def pkt4_reg(w: int) -> int:
    return (w >> 8) & 0x3FFFF


def pkt4_cnt(w: int) -> int:
    return w & 0x7F


def iter_sections(data: bytes):
    off = 0
    n = len(data)
    while off + 8 <= n:
        typ, sz = struct.unpack_from("<II", data, off)
        off += 8
        if sz > n - off:
            break
        yield typ, data[off : off + sz]
        off += sz


def load_rd(path: Path):
    raw = path.read_bytes()
    gpu = {}
    streams = []
    gpu_id = None
    for typ, payload in iter_sections(raw):
        if typ == RD_GPU_ID and len(payload) >= 4:
            gpu_id = struct.unpack_from("<I", payload)[0]
        elif typ == RD_GPUADDR and len(payload) >= 8:
            addr, size = struct.unpack_from("<II", payload)
            hi = struct.unpack_from("<I", payload, 8)[0] if len(payload) >= 12 else 0
            gpu["_pending"] = (addr | (hi << 32), size)
        elif typ == RD_BUFFER_CONTENTS:
            pend = gpu.pop("_pending", None)
            if pend:
                gpu[pend[0]] = payload
        elif typ == RD_CMDSTREAM_ADDR and len(payload) >= 8:
            addr, dwords = struct.unpack_from("<II", payload)
            hi = struct.unpack_from("<I", payload, 8)[0] if len(payload) >= 12 else 0
            streams.append((addr | (hi << 32), dwords))
        elif typ == RD_CMDSTREAM:
            streams.append((None, len(payload) // 4, payload))
    return gpu_id, gpu, streams


def words_at(gpu: dict, addr: int, dwords: int):
    for base, blob in gpu.items():
        if not isinstance(base, int):
            continue
        if addr >= base and (addr - base) + dwords * 4 <= len(blob):
            off = addr - base
            return struct.unpack_from("<%dI" % dwords, blob, off)
    return None


def scan_ib(words, gpu, depth=0, seen=None):
    if seen is None:
        seen = set()
    hits = []
    if not words:
        return hits
    i = 0
    n = len(words)
    while i < n:
        w = words[i]
        if pkt7_ok(w):
            op = pkt7_op(w)
            cnt = pkt7_cnt(w)
            body = words[i + 1 : i + 1 + cnt]
            if op == CP_SET_RENDER_MODE:
                mode = body[0] if body else -1
                hits.append((depth, i, "CP_SET_RENDER_MODE", RM6.get(mode, hex(mode)), body[:4]))
            elif op == CP_BLIT:
                hits.append((depth, i, "CP_BLIT", body[0] if body else None, body[:6]))
            elif op == CP_EVENT_WRITE:
                ev = body[0] if body else None
                evn = EVENTS.get(ev & 0xFF if ev is not None else -1, ev)
                hits.append((depth, i, "CP_EVENT_WRITE", evn, body[:6]))
            elif op in (CP_DRAW_INDX, CP_DRAW_INDX_OFFSET, CP_DRAW_INDIRECT, CP_DRAW_AUTO):
                hits.append((depth, i, "CP_DRAW", hex(op), body[:4]))
            elif op in (CP_INDIRECT_BUFFER_PFE, CP_INDIRECT_BUFFER_PFD) and len(body) >= 3:
                lo, hi, sz = body[0], body[1], body[2]
                ib = (lo | (hi << 32), sz)
                if ib not in seen:
                    seen.add(ib)
                    sub = words_at(gpu, ib[0], ib[1])
                    hits.append((depth, i, "IB", hex(ib[0]), ib[1]))
                    if sub:
                        hits.extend(scan_ib(sub, gpu, depth + 1, seen))
            i += 1 + cnt
            continue
        if pkt4_ok(w):
            reg = pkt4_reg(w)
            cnt = pkt4_cnt(w)
            # RB_MRT_BUF_INFO = 0x8810-ish on a6xx; print interesting color/2d regs.
            interesting = {
                0x8810: "RB_MRT_BUF_INFO",
                0x8811: "RB_MRT_PITCH",
                0x8812: "RB_MRT_ARRAY_PITCH",
                0x8813: "RB_MRT_BASE",
                0x8814: "RB_MRT_BASE_HI",
                0x8C17: "RB_2D_DST_INFO",
                0x8C18: "RB_2D_DST_PITCH",
                0x8C19: "RB_2D_DST",
                0x8C1A: "RB_2D_DST_HI",
                0x8C01: "RB_2D_SRC_INFO",
                0x8005: "RB_CCU_CNTL",
                0x8008: "RB_WINDOW_OFFSET",
                0x88e3: "RB_RESOLVE_OPERATION",
                0x880C: "RB_RESOLVE_CNTL_1",
                0x880D: "RB_RESOLVE_CNTL_2",
                0x880E: "RB_RESOLVE_CNTL_3",
                0x8C34: "GRAS_2D_DST_INFO",
            }
            name = interesting.get(reg)
            if name:
                vals = words[i + 1 : i + 1 + cnt]
                hits.append((depth, i, "REG", f"{name}(0x{reg:x})", vals[:8]))
            i += 1 + cnt
            continue
        i += 1
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rd", type=Path)
    args = ap.parse_args()
    if not args.rd.exists():
        print(f"missing {args.rd}", file=sys.stderr)
        sys.exit(2)
    gpu_id, gpu, streams = load_rd(args.rd)
    print(f"file={args.rd} gpu_id={gpu_id} buffers={len(gpu)} streams={len(streams)} bytes={args.rd.stat().st_size}")
    modes = []
    blits = 0
    events = 0
    ibs = 0
    draws = 0
    resolves = []
    for item in streams:
        if len(item) == 3:
            addr, dwords, payload = item
            words = struct.unpack("<%dI" % dwords, payload[: dwords * 4])
        else:
            addr, dwords = item
            words = words_at(gpu, addr, dwords)
            print(f"  stream gpu=0x{addr:x} dwords={dwords} resolved={words is not None}")
        if not words:
            continue
        for hit in scan_ib(words, gpu):
            depth, idx, kind, extra, extra2 = hit if len(hit) == 5 else (*hit, None)
            pad = "  " * (depth + 1)
            print(f"{pad}[{idx}] {kind} {extra} {extra2}")
            if kind == "CP_SET_RENDER_MODE":
                modes.append(str(extra))
            elif kind == "CP_BLIT":
                blits += 1
            elif kind == "CP_EVENT_WRITE":
                events += 1
            elif kind == "CP_DRAW":
                draws += 1
            elif kind == "IB":
                ibs += 1
            elif kind == "REG" and isinstance(extra, str) and extra.startswith("RB_RESOLVE_OPERATION"):
                val = extra2[0] if extra2 else 0
                typ = val & 3
                tname = {0: "STORE", 1: "STORE_AND_CLEAR", 3: "LOAD"}.get(typ, hex(typ))
                resolves.append(tname)
                print(f"{pad}    decode TYPE={tname} LAST={(val >> 8) & 3} MASK={(val >> 4) & 0xf} raw=0x{val:x}")
    gmemish = any(m.startswith("RM6_BIN") for m in modes)
    bypass = any(m == "RM6_DIRECT_RENDER" for m in modes)
    print("--- summary ---")
    print(f"render_modes={modes}")
    print(f"cp_blit={blits} event_write={events} draws={draws} ibs={ibs}")
    print(f"resolve_ops={resolves}")
    if gmemish and not bypass:
        print("JUDGEMENT_HINT=GMEM_OR_RESOLVE_PRESENT")
    elif bypass and not gmemish:
        print("JUDGEMENT_HINT=SYSMEM_BYPASS")
    elif bypass and gmemish:
        print("JUDGEMENT_HINT=MIXED")
    elif not modes:
        print("JUDGEMENT_HINT=NO_RENDER_MODE_SEEN")
    else:
        print("JUDGEMENT_HINT=SEE_MODES")
    # Two-subpass FB-fetch: A = both draws stay in one GMEM bin pass;
    # B = STORE (or DIRECT) appears as a mid-pass cut so subpass1 samples sysmem.
    if gmemish and "LOAD" not in resolves and draws >= 2:
        print("FBREAD_HINT=VERDICT_A_LIKELY_PURE_GMEM")
    elif gmemish and ("STORE" in resolves or "STORE_AND_CLEAR" in resolves) and "LOAD" in resolves:
        print("FBREAD_HINT=VERDICT_B_STORE_THEN_LOAD")
    elif bypass and not gmemish:
        print("FBREAD_HINT=VERDICT_B_OR_SYSMEM_ONLY")


if __name__ == "__main__":
    main()
