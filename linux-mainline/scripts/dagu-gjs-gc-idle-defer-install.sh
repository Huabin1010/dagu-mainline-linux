#!/usr/bin/env bash
# Live-only: trigger_gc_if_needed (libgjs 0xa8624) defers JS_GC / gjs_gc_if_needed
# while the Clutter frame clock is scheduled, or until two consecutive 10s
# fires see ready_time==-1. queue_callback also stamps g_get_monotonic_time
# into gjs .bss; if last qcb <250ms, defer.
#
# Not skip-hammer (JS_GC still runs after compositor idle).
# Not MaybeGC / inc-slice / KMS interrupt / 4ms budget.
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
SITE = 0xa8638
STOCK = 0xb900581f  # str wzr,[x0,#88]
CAVE = 0xb00a0
MONO_PLT = 0x26aa0
MU_RET = 0x1d6f28
MU_RET_STOCK = 0xd65f03c0
MU_CAVE = 0x1d2b80
MU_MONO_PLT = 0x68270
# gjs file rw last page: process VA computed at apply
SLOT_OFF = 0x1a0fe0  # last_qcb u64 + strike u32 in gjs rw (file 0x1a0000 + 0xfe0)


def bl(pc, tgt):
    return 0x94000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def b(pc, tgt):
    return 0x14000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def mov_imm64(rd, imm):
    words = [0xD2800000 | ((imm & 0xFFFF) << 5) | rd]
    for sh, enc in ((16, 0xF2A00000), (32, 0xF2C00000), (48, 0xF2E00000)):
        hw = (imm >> sh) & 0xFFFF
        if hw:
            words.append(enc | (hw << 5) | rd)
    return words


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
        gjs = mu = cl = None
        gjs_rw = mu_rx = None
        for line in (p / "maps").read_text().splitlines():
            rng, perm, off, *rest = line.split()
            path = rest[-1] if rest else ""
            lo = int(rng.split("-")[0], 16)
            if "libgjs.so" in path and "r-xp" in perm:
                gjs = lo
            if "libgjs.so" in path and perm.startswith("rw"):
                gjs_rw = lo
            if "libmutter-18.so.0.0.0" in path and "mutter-18/" not in path and "r-xp" in perm:
                mu = lo
                mu_rx = lo
            if "libmutter-clutter-18" in path and perm.startswith("rw"):
                cl_rw = lo
            if "libmutter-clutter-18" in path and "r-xp" in perm:
                cl = lo
        if gjs and mu and gjs_rw:
            return int(p.name), gjs, mu, gjs_rw, cl if "cl" in dir() else None
    raise SystemExit("no ubuntu gnome-shell")


def find_clock(pid, cl_rw):
    if cl_rw is None:
        for line in open(f"/proc/{pid}/maps"):
            if "libmutter-clutter-18" in line and line.split()[1].startswith("rw"):
                cl_rw = int(line.split("-")[0], 16)
                break
    funcs = cl_rw + 0x160
    needle = struct.pack("<Q", funcs)
    mem = open(f"/proc/{pid}/mem", "rb")
    for line in open(f"/proc/{pid}/maps"):
        perm = line.split()[1]
        if not perm.startswith("rw"):
            continue
        rng = line.split()[0]
        a, b = [int(x, 16) for x in rng.split("-")]
        try:
            mem.seek(a)
            data = mem.read(b - a)
        except OSError:
            continue
        k = data.find(needle)
        if k < 0:
            continue
        src = a + k - 16
        mem.seek(src + 40)
        prio = struct.unpack("<i", mem.read(4))[0]
        if prio == 150:
            return src
    raise SystemExit("no clutter frame clock GSource")


def assemble_gjs(gjs, slot, clock):
    words = []

    def here():
        return gjs + CAVE + 4 * len(words)

    def emit(w):
        words.append(w & 0xFFFFFFFF)

    # x19 = gjs ctx, frame already open
    emit(bl(here(), gjs + MONO_PLT))
    for w in mov_imm64(1, slot):
        emit(w)
    emit(0xF9400022)  # ldr x2,[x1]
    emit(0xB4000002)  # cbz x2, check_clock (patch)
    cbz_qcb = len(words) - 1
    emit(0xCB020002)  # sub x2,x0,x2
    emit(0xD2BA1203)  # movz x3,#0xd090
    emit(0xF2A00063)  # movk x3,#0x3,lsl#16  ; 250000 us
    emit(0xEB03005F)  # cmp x2,x3
    emit(0x54000003)  # b.lo defer (patch)
    blo_qcb = len(words) - 1

    check_clock = here()
    words[cbz_qcb] = 0xB4000002 | ((((check_clock - (gjs + CAVE + 4 * cbz_qcb)) // 4) & 0x7FFFF) << 5)
    for w in mov_imm64(0, clock):
        emit(w)
    emit(0xF9402C00)  # ldr x0,[x0,#88] priv
    emit(0xB4000080)  # cbz x0, stock
    cbz_priv = len(words) - 1
    emit(0xF9400800)  # ldr x0,[x0,#16] ready_time
    emit(0xB1000400)  # cmn x0,#1
    emit(0x54000040)  # b.eq strike
    beq_idle = len(words) - 1
    # busy clock: clear strike, defer
    for w in mov_imm64(0, slot + 8):
        emit(w)
    emit(0xB900001F)  # str wzr,[x0]
    emit(0x14000000)  # b defer
    b_busy = len(words) - 1

    strike = here()
    words[beq_idle] = 0x54000000 | ((((strike - (gjs + CAVE + 4 * beq_idle)) // 4) & 0x7FFFF) << 5)
    for w in mov_imm64(0, slot + 8):
        emit(w)
    emit(0xB9400001)  # ldr w1,[x0]
    emit(0x11000421)  # add w1,w1,#1
    emit(0xB9000001)  # str w1,[x0]
    emit(0x7100083F)  # cmp w1,#2
    emit(0x5400002A)  # b.ge stock_reset
    bge_stock = len(words) - 1
    emit(0x14000000)  # b defer
    b_strike_def = len(words) - 1

    defer = here()
    words[blo_qcb] = 0x54000003 | ((((defer - (gjs + CAVE + 4 * blo_qcb)) // 4) & 0x7FFFF) << 5)
    words[b_busy] = b(gjs + CAVE + 4 * b_busy, defer)
    words[b_strike_def] = b(gjs + CAVE + 4 * b_strike_def, defer)
    emit(0xF9400BF3)  # ldr x19,[sp,#16]
    emit(0xA8C27BFD)  # ldp x29,x30,[sp],#32
    emit(0xD50323BF)  # autiasp
    emit(0x52800020)  # mov w0,#1
    emit(0xD65F03C0)  # ret

    stock_reset = here()
    words[bge_stock] = 0x5400000A | ((((stock_reset - (gjs + CAVE + 4 * bge_stock)) // 4) & 0x7FFFF) << 5)
    for w in mov_imm64(0, slot + 8):
        emit(w)
    emit(0xB900001F)  # str wzr,[x0]

    stock = here()
    words[cbz_priv] = 0xB4000000 | ((((stock - (gjs + CAVE + 4 * cbz_priv)) // 4) & 0x7FFFF) << 5)
    emit(0xB9005A7F)  # str wzr,[x19,#88]
    emit(0xAA1303E0)  # mov x0,x19
    emit(b(here(), gjs + 0xA863C))
    return words


def assemble_mu(mu, slot):
    words = []

    def here():
        return mu + MU_CAVE + 4 * len(words)

    def emit(w):
        words.append(w & 0xFFFFFFFF)

    emit(0xF81F0FFE)  # str x30,[sp,#-16]!
    emit(bl(here(), mu + MU_MONO_PLT))
    for w in mov_imm64(1, slot):
        emit(w)
    emit(0xF9000020)  # str x0,[x1]
    emit(0xF84107FE)  # ldr x30,[sp],#16
    emit(0xD65F03C0)  # ret
    return words


pid, gjs, mu, gjs_rw, cl = find_ubuntu()
slot = gjs_rw + (SLOT_OFF & 0xFFF)  # rw map file 0x1a0000 → va+0xfe0 if map starts at file 1a0000
# verify rw file offset
for line in open(f"/proc/{pid}/maps"):
    if "libgjs.so" in line and line.split()[1].startswith("rw"):
        fo = int(line.split()[2], 16)
        lo = int(line.split("-")[0], 16)
        slot = lo + (0x1A0FE0 - fo)
        break

mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(gjs + SITE)
site = struct.unpack("<I", mem.read(4))[0]
mem.seek(mu + MU_RET)
muret = struct.unpack("<I", mem.read(4))[0]
clock = find_clock(pid, None)
print(f"pid={pid} gjs={gjs:#x} mu={mu:#x} slot={slot:#x} clock={clock:#x}")
print(f"a8638={site:#x} mu_ret={muret:#x}")

if cmd == "status":
    print("gjs", "poked" if site == b(gjs + SITE, gjs + CAVE) else ("stock" if site == STOCK else hex(site)))
    print("mu", "poked" if muret == b(mu + MU_RET, mu + MU_CAVE) else ("stock" if muret == MU_RET_STOCK else hex(muret)))
    mem.seek(slot)
    print("slot", mem.read(16).hex())
elif cmd == "apply-live":
    gw = assemble_gjs(gjs, slot, clock)
    mw = assemble_mu(mu, slot)
    mem.seek(gjs + CAVE)
    mem.write(struct.pack("<" + "I" * len(gw), *gw))
    mem.seek(mu + MU_CAVE)
    mem.write(struct.pack("<" + "I" * len(mw), *mw))
    mem.seek(slot)
    mem.write(b"\x00" * 16)
    mem.seek(gjs + SITE)
    mem.write(struct.pack("<I", b(gjs + SITE, gjs + CAVE)))
    mem.seek(mu + MU_RET)
    mem.write(struct.pack("<I", b(mu + MU_RET, mu + MU_CAVE)))
    mem.seek(gjs + SITE)
    print("wrote a8638", hex(struct.unpack("<I", mem.read(4))[0]), "caveins", len(gw), "muins", len(mw))
elif cmd == "restore-live":
    mem.seek(gjs + SITE)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(mu + MU_RET)
    mem.write(struct.pack("<I", MU_RET_STOCK))
    mem.seek(gjs + CAVE)
    mem.write(b"\x00" * 256)
    mem.seek(mu + MU_CAVE)
    mem.write(b"\x00" * 64)
    print("restored")
else:
    raise SystemExit("usage: status|apply-live|restore-live")
mem.close()
PY
