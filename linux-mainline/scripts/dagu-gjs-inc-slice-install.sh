#!/usr/bin/env bash
# Live-only: trigger_gc_if_needed JS_GC(BIG_HAMMER) → one IncrementalGC slice
# and g_idle_add_full(G_PRIORITY_LOW) until done. Frame clock (prio 150) runs first.
# Cave at libgjs 0xb00a0 (4096-byte nop run). Does not write disk so.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

"${SSH[@]}" python3 - "$cmd" <<'PY'
import struct, pathlib, sys
cmd = sys.argv[1]
SITE = 0xa864c
STOCK = 0x97fdf489  # bl JS_GC
CAVE = 0xb00a0
TRIGGER = 0xa8624
CLEAR = 0xa8650
NOCLEAR = 0xa865c
# mozjs file offs (objdump of board libmozjs-140.so.140.8.0)
OFF_INPROG = 0x61c6e0
OFF_SLICE = 0x62dda0
OFF_START = 0x62dca0
OFF_TIME = 0x60c1e0  # SliceBudget(TimeBudget, Atomic*)
OFF_TICKS = 0xbe3820  # TicksFromMilliseconds(double)
IDLE_PLT = 0x26d30
# G_PRIORITY_DEFAULT_IDLE=200: after frame clock 150, before G_PRIORITY_LOW
IDLE_PRIO = 200


def bl(pc, tgt):
    return 0x94000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def b(pc, tgt):
    return 0x14000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def adr(pc, tgt, rd):
    imm = tgt - pc
    assert imm % 4 == 0 and abs(imm) < (1 << 20)
    immlo = imm & 3
    immhi = (imm >> 2) & 0x7FFFF
    return 0x10000000 | (immlo << 29) | (immhi << 5) | rd


def find_ubuntu():
    for p in pathlib.Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            c = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if not c.startswith(b"/usr/bin/gnome-shell") or b"--mode=ubuntu" not in c:
            continue
        gjs = moz = None
        for line in (p / "maps").read_text().splitlines():
            if "libgjs.so" in line and "r-xp" in line:
                gjs = int(line.split("-", 1)[0], 16)
            elif "libmozjs-140" in line and "r-xp" in line:
                moz = int(line.split("-", 1)[0], 16)
        if gjs and moz:
            return int(p.name), gjs, moz
    raise SystemExit("no ubuntu gnome-shell gjs/mozjs")


# Pop cave frame then resume trigger epilogue (site is `b cave`, not `bl`).
POP_X19X20 = 0xa94153f3  # ldp x19,x20,[sp,#16]
POP_FP_LR = 0xa8c87bfd   # ldp x29,x30,[sp],#128


def assemble_va(gjs, moz):
    words = []

    def here():
        return gjs + CAVE + 4 * len(words)

    def emit(w):
        words.append(w & 0xFFFFFFFF)

    # 128-byte frame: SliceBudget (~48B) at sp+64
    emit(0xa9b87bfd)  # stp x29,x30,[sp,#-128]!
    emit(0x910003fd)  # mov x29,sp
    emit(0xa90153f3)  # stp x19,x20,[sp,#16]
    emit(0xf90013e0)  # str x0,[sp,#32] cx
    emit(0xb9002be1)  # str w1,[sp,#40] incoming (MEM_PRESSURE=0x23, unused)
    emit(bl(here(), moz + OFF_INPROG))
    emit(0x2a0003f4)  # mov w20,w0
    # TimeBudget 1ms: TicksFromMilliseconds(1.0)
    emit(0xd2e7fe08)  # movz x8,#0x3ff0,lsl#48  ; 1.0
    emit(0x9e670100)  # fmov d0,x8
    emit(bl(here(), moz + OFF_TICKS))
    emit(0xaa0003e1)  # mov x1,x0
    emit(0x910103e0)  # add x0,sp,#64
    emit(0xd2800002)  # mov x2,#0
    emit(0xd2800003)  # mov x3,#0
    emit(bl(here(), moz + OFF_TIME))
    cbnz_i = len(words)
    emit(0x35000014)
    emit(0xf94013e0)  # ldr x0,[sp,#32]
    emit(0x52800001)  # mov w1,#0 Normal
    emit(0x52800022)  # mov w2,#1 EAGER_ALLOC_TRIGGER (not MEM_PRESSURE)
    emit(0x910103e3)  # add x3,sp,#64
    emit(bl(here(), moz + OFF_START))
    b_after_i = len(words)
    emit(0x14000000)
    do_slice = here()
    emit(0xf94013e0)
    emit(0x528005e1)  # mov w1,#0x2f INTER_SLICE_GC
    emit(0x910103e2)  # add x2,sp,#64
    emit(bl(here(), moz + OFF_SLICE))
    after = here()
    words[cbnz_i] = 0x35000000 | (
        (((do_slice - (gjs + CAVE + 4 * cbnz_i)) // 4) & 0x7FFFF) << 5
    ) | 20
    words[b_after_i] = b(gjs + CAVE + 4 * b_after_i, after)
    emit(0xf94013e0)
    emit(bl(here(), moz + OFF_INPROG))
    cbz_i = len(words)
    emit(0x34000000)
    emit(0x52801900)  # mov w0,#200 DEFAULT_IDLE
    emit(adr(here(), gjs + TRIGGER, 1))
    emit(0xaa1303e2)  # mov x2,x19
    emit(0xd2800003)  # mov x3,#0
    emit(bl(here(), gjs + IDLE_PLT))
    emit(0xb9005a60)  # str w0,[x19,#88] m_auto_gc_id
    emit(POP_X19X20)
    emit(POP_FP_LR)
    emit(b(here(), gjs + NOCLEAR))
    do_clear = here()
    words[cbz_i] = 0x34000000 | (
        (((do_clear - (gjs + CAVE + 4 * cbz_i)) // 4) & 0x7FFFF) << 5
    )
    emit(POP_X19X20)
    emit(POP_FP_LR)
    emit(b(here(), gjs + CLEAR))
    return b"".join(struct.pack("<I", w) for w in words)


pid, gjs, moz = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(gjs + SITE)
cur = struct.unpack("<I", mem.read(4))[0]
blob = assemble_va(gjs, moz)
site_b = b(gjs + SITE, gjs + CAVE)
print(f"pid={pid} gjs={gjs:#x} moz={moz:#x} a864c={cur:#x} cave_bytes={len(blob)} site_b={site_b:#x}")
if cmd == "apply-live":
    mem.seek(gjs + CAVE)
    mem.write(blob)
    mem.seek(gjs + SITE)
    mem.write(struct.pack("<I", site_b))
    mem.seek(gjs + SITE)
    print("wrote site", hex(struct.unpack("<I", mem.read(4))[0]))
elif cmd == "restore-live":
    mem.seek(gjs + SITE)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(gjs + SITE)
    print("restored site", hex(struct.unpack("<I", mem.read(4))[0]))
else:
    print("stock" if cur == STOCK else ("poked" if cur == site_b else hex(cur)))
mem.close()
PY
