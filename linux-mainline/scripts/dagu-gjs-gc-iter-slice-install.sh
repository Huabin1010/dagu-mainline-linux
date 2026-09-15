#!/usr/bin/env bash
# Live-only: JS_GC(BIG_HAMMER) → up to 4× IncrementalGCSlice(2ms),
# each followed by g_main_context_iteration(NULL, FALSE) so nview/clock
# can run on the same main thread before we return.
# If still in progress: g_idle_add_full(200, trigger) and keep m_force_gc.
#
# Not idle-defer, not MaybeGC, not 4ms JS_GC budget, not KMS interrupt.
# Not the rejected 1-slice + idle-only cave (dagu-gjs-inc-slice-install.sh).
# Does not write disk so. Does not restart gnome-shell.
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
OFF_INPROG = 0x61c6e0
OFF_SLICE = 0x62dda0
OFF_START = 0x62dca0
OFF_TIME = 0x60c1e0
OFF_TICKS = 0xbe3820
IDLE_PLT = 0x26d30
ITER_PLT = 0x25660
IDLE_PRIO = 200
MAX_SLICES = 4


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


def assemble_va(gjs, moz):
    words = []

    def here():
        return gjs + CAVE + 4 * len(words)

    def emit(w):
        words.append(w & 0xFFFFFFFF)

    # 128B: SliceBudget at sp+64; x0 cx at sp+32; w21 = remaining
    emit(0xA9B87BFD)  # stp x29,x30,[sp,#-128]!
    emit(0x910003FD)  # mov x29,sp
    emit(0xA9015BF5)  # stp x21,x22,[sp,#16]
    emit(0xF90013E0)  # str x0,[sp,#32] cx
    emit(0x52800095)  # mov w21,#4

    loop = here()
    # fresh 2ms TimeBudget each slice
    emit(0xD2E80008)  # movz x8,#0x4000,lsl#48  ; 2.0
    emit(0x9E670100)  # fmov d0,x8
    emit(bl(here(), moz + OFF_TICKS))
    emit(0xAA0003E1)  # mov x1,x0
    emit(0x910103E0)  # add x0,sp,#64
    emit(0xD2800002)  # mov x2,#0
    emit(0xD2800003)  # mov x3,#0
    emit(bl(here(), moz + OFF_TIME))
    emit(0xF94013E0)  # ldr x0,[sp,#32]
    emit(bl(here(), moz + OFF_INPROG))
    emit(0x34000080)  # cbz w0, do_start (patch)
    cbz_start = len(words) - 1
    emit(0xF94013E0)
    emit(0x528005E1)  # mov w1,#0x2f INTER_SLICE_GC
    emit(0x910103E2)  # add x2,sp,#64
    emit(bl(here(), moz + OFF_SLICE))
    emit(0x14000000)  # b after_gc
    b_after = len(words) - 1
    do_start = here()
    words[cbz_start] = 0x34000000 | (
        (((do_start - (gjs + CAVE + 4 * cbz_start)) // 4) & 0x7FFFF) << 5
    )
    emit(0xF94013E0)
    emit(0x52800001)  # mov w1,#0 Normal
    emit(0x52800022)  # mov w2,#1 EAGER_ALLOC_TRIGGER
    emit(0x910103E3)  # add x3,sp,#64
    emit(bl(here(), moz + OFF_START))
    after_gc = here()
    words[b_after] = b(gjs + CAVE + 4 * b_after, after_gc)
    # nest GLib: nview / clock can run
    emit(0xD2800000)  # mov x0,#0 default ctx
    emit(0xD2800001)  # mov x1,#0 may_block=FALSE
    emit(bl(here(), gjs + ITER_PLT))
    emit(0xF94013E0)
    emit(bl(here(), moz + OFF_INPROG))
    emit(0x34000000)  # cbz w0, done (patch)
    cbz_done = len(words) - 1
    emit(0x710006B5)  # subs w21,w21,#1
    emit(0x54FF0001)  # b.ne loop (patch)
    bne_loop = len(words) - 1
    # still in progress: idle 200, keep force_gc
    emit(0x52801900)  # mov w0,#200
    emit(adr(here(), gjs + TRIGGER, 1))
    emit(0xAA1303E2)  # mov x2,x19
    emit(0xD2800003)  # mov x3,#0
    emit(bl(here(), gjs + IDLE_PLT))
    emit(0xB9005A60)  # str w0,[x19,#88]
    emit(0xA9415BF5)  # ldp x21,x22,[sp,#16]
    emit(0xA8C87BFD)  # ldp x29,x30,[sp],#128
    emit(b(here(), gjs + NOCLEAR))
    done = here()
    words[cbz_done] = 0x34000000 | (
        (((done - (gjs + CAVE + 4 * cbz_done)) // 4) & 0x7FFFF) << 5
    )
    words[bne_loop] = 0x54000001 | (
        (((loop - (gjs + CAVE + 4 * bne_loop)) // 4) & 0x7FFFF) << 5
    )
    emit(0xA9415BF5)
    emit(0xA8C87BFD)
    emit(b(here(), gjs + CLEAR))
    return [w & 0xFFFFFFFF for w in words]


pid, gjs, moz = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(gjs + SITE)
cur = struct.unpack("<I", mem.read(4))[0]
words = assemble_va(gjs, moz)
blob = b"".join(struct.pack("<I", w) for w in words)
site_b = b(gjs + SITE, gjs + CAVE)
print(f"pid={pid} gjs={gjs:#x} moz={moz:#x} a864c={cur:#x} caveins={len(words)} site_b={site_b:#x}")
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
    mem.seek(gjs + CAVE)
    mem.write(b"\x00" * 256)
    print("restored")
elif cmd == "status":
    print("stock" if cur == STOCK else ("poked" if cur == site_b else hex(cur)))
else:
    raise SystemExit("usage: status|apply-live|restore-live")
mem.close()
PY
