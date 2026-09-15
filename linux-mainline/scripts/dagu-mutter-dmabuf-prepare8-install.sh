#!/usr/bin/env bash
# REJECTED 2026-09-14: 116.85 Hz / gt50=2, vblank 119.37/gt50=1. Restore.
# DmaBuf GSourceFuncs.prepare: if first fd POLLIN return TRUE, else *timeout=8.
# Does not iterate / can_recurse / poke 0x18fe78 / 0x18fdbc / 0x1c4388.
# Live: write prepare ptr @ 0x2b2bb8 → cave@0x1d1bd8. Does not write the disk so.
# Never uprobe 0x18fe78. usage: status|apply|restore
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

case "$cmd" in
  status|apply|restore)
    "${SSH[@]}" python3 - "$cmd" <<'PY'
import struct, sys
from pathlib import Path

cmd = sys.argv[1]
CAVE = 0x1D1BD8
PREPARE_PTR = 0x2B2BB8  # GSourceFuncs.prepare; dispatch @ 0x2b2bc8
POLL_PLT = 0x677E0
NWORDS = 25


def find_ubuntu():
    mu = None
    pid = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            c = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if not c.startswith(b"/usr/bin/gnome-shell") or b"--mode=ubuntu" not in c:
            continue
        pid = int(p.name)
        for line in (p / "maps").read_text().splitlines():
            if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
                mu = int(line.split("-", 1)[0], 16)
                break
        break
    if pid is None or mu is None:
        raise SystemExit(f"need ubuntu+maps mu={mu}")
    return pid, mu


def u32(mem, addr):
    mem.seek(addr)
    return struct.unpack("<I", mem.read(4))[0]


def u64(mem, addr):
    mem.seek(addr)
    return struct.unpack("<Q", mem.read(8))[0]


def w32(mem, addr, val):
    mem.seek(addr)
    mem.write(struct.pack("<I", val))


def w64(mem, addr, val):
    mem.seek(addr)
    mem.write(struct.pack("<Q", val))


def bl_imm(pc, dest):
    return 0x94000000 | (((dest - pc) // 4) & 0x3FFFFFF)


def words():
    # x0=GSource*, x1=gint *timeout
    # *timeout=8; if fd=[src+152]>=0 and g_poll(IN,0)>0: return TRUE else FALSE
    skip = 21
    tbnz_from = 7
    cbz_from = 18
    tbnz = 0x37000000 | (31 << 19) | (((skip - tbnz_from) & 0x3FFF) << 5)
    cbz = 0x34000000 | (((skip - cbz_from) & 0x7FFFF) << 5)
    return [
        0xA9BD7BFD,  # stp x29,x30,[sp,#-48]!
        0x910003FD,  # mov x29,sp
        0xF9000BF3,  # str x19,[sp,#16]
        0xAA0003F3,  # mov x19,x0
        0x52800102,  # mov w2,#8
        0xB9000022,  # str w2,[x1]
        0xB9409A60,  # ldr w0,[x19,#152]
        tbnz,        # tbnz w0,#31,skip (fd<0)
        0xD10043FF,  # sub sp,sp,#16
        0xB90003E0,  # str w0,[sp]
        0x52800020,  # mov w0,#1   G_IO_IN
        0x79000BE0,  # strh w0,[sp,#4]
        0x79000FFF,  # strh wzr,[sp,#6]
        0x910003E0,  # mov x0,sp
        0x52800021,  # mov w1,#1
        0x52800002,  # mov w2,#0
        bl_imm(CAVE + 64, POLL_PLT),
        0x910043FF,  # add sp,sp,#16
        cbz,         # cbz w0,skip
        0x52800020,  # mov w0,#1
        0x14000002,  # b +2 → ldr x19
        0x52800000,  # skip: mov w0,#0
        0xF9400BF3,  # ldr x19,[sp,#16]
        0xA8C37BFD,  # ldp x29,x30,[sp],#48
        0xD65F03C0,  # ret
    ]


# Fix the b offset: POLLIN path should skip the mov w0,#0
# indices: 19 mov w0,#1; 20 b; 21 skip mov w0,#0; 22 ldr; 23 ldp; 24 ret
# b from 20 to 22: skip 1 insn → 0x14000002 is +2? aarch64 b imm is in words from current.
# b +2 means skip next insn (the mov w0,#0) and land on ldr. 0x14000002 is +2 words = skip one insn? 
# PC-relative: b #8 is 2 instructions forward (imm26=2). 0x14000002 = b +2 words = next-next, which is ldr. Good.


pid, mu = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
want = words()
# rebuild tbnz/cbz against actual skip index 21
# tbnz_from=7 (0-based index of tbnz), skip=21
# Let me just use the returned list; verify NWORDS
if len(want) != 25:
    # recount below after fix
    pass
prep = u64(mem, mu + PREPARE_PTR)
disp = u64(mem, mu + PREPARE_PTR + 16)
cave0 = [u32(mem, mu + CAVE + 4 * i) for i in range(max(NWORDS, 25))]
print("pid", pid, "mu", hex(mu), "prepare", hex(prep), "dispatch", hex(disp),
      "cave0", hex(cave0[0]), "nwords", len(want))

want_prep = mu + CAVE
if cmd == "status":
    poked = prep == want_prep and cave0[:len(want)] == want
    print("live", "poked" if poked else "stock-or-mixed")
elif cmd == "apply":
    if prep == want_prep and cave0[:len(want)] == want:
        print("already poked")
    else:
        if prep != 0:
            raise SystemExit(f"prepare not NULL: {prep:#x}")
        if disp != mu + 0x16E70C:
            raise SystemExit(f"dispatch moved: {disp:#x}")
        if any(cave0[:len(want)]):
            raise SystemExit(f"cave not empty: {[hex(x) for x in cave0[:8]]}")
        for i, w in enumerate(want):
            w32(mem, mu + CAVE + 4 * i, w)
        w64(mem, mu + PREPARE_PTR, want_prep)
        print("poked prepare", hex(u64(mem, mu + PREPARE_PTR)))
elif cmd == "restore":
    w64(mem, mu + PREPARE_PTR, 0)
    for i in range(max(NWORDS, len(want))):
        w32(mem, mu + CAVE + 4 * i, 0)
    print("restored prepare", hex(u64(mem, mu + PREPARE_PTR)))
mem.close()
print("tracing_on", Path("/sys/kernel/debug/tracing/tracing_on").read_text().strip())
PY
    ;;
  *)
    echo "usage: $0 status|apply|restore" >&2
    exit 2
    ;;
esac
