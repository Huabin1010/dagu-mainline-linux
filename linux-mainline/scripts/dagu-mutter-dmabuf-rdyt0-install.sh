#!/usr/bin/env bash
# After DmaBuf g_source_attach, if first sync fd is already POLLIN,
# g_source_set_ready_time(src, 0). Does not iterate / can_recurse.
# Live 0x18fe78 bl attach → bl cave@0x1d1bd8.
# Does not touch 0x1d2b80 / 0x1c4388 / 0x18ff40 / 0x18fdbc.
# Never uprobe 0x18fe78 while poked.
# Does not write the disk so.
# usage: status|apply|restore
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
SITE = 0x18FE78
SITE_STOCK = 0x97FB5576  # bl g_source_attach@plt
CAVE = 0x1D1BD8
ATTACH_PLT = 0x65450
POLL_PLT = 0x677E0
READY_PLT = 0x675E0
NWORDS = 28


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


def w32(mem, addr, val):
    mem.seek(addr)
    mem.write(struct.pack("<I", val))


def bl_imm(pc, dest):
    return 0x94000000 | (((dest - pc) // 4) & 0x3FFFFFF)


def words():
    # cave: attach; if [src+152]>=0 and g_poll(fd,IN,0)>0: set_ready_time(src,0)
    skip = 23
    tbnz_from = 8
    cbz_from = 19
    tbnz = 0x37000000 | (31 << 19) | (((skip - tbnz_from) & 0x3FFF) << 5)
    cbz = 0x34000000 | (((skip - cbz_from) & 0x7FFFF) << 5)
    return [
        0xA9BD7BFD,  # stp x29,x30,[sp,#-48]!
        0x910003FD,  # mov x29,sp
        0xA90153F3,  # stp x19,x20,[sp,#16]
        0xF90013F5,  # str x21,[sp,#32]
        0xAA0003F3,  # mov x19,x0
        bl_imm(CAVE + 20, ATTACH_PLT),
        0xAA0003F4,  # mov x20,x0
        0xB9409A60,  # ldr w0,[x19,#152]
        tbnz,        # tbnz w0,#31,skip
        0xD10043FF,  # sub sp,sp,#16
        0xB90003E0,  # str w0,[sp]
        0x52800020,  # mov w0,#1
        0x79000BE0,  # strh w0,[sp,#4]
        0x79000FFF,  # strh wzr,[sp,#6]
        0x910003E0,  # mov x0,sp
        0x52800021,  # mov w1,#1
        0x52800002,  # mov w2,#0
        bl_imm(CAVE + 68, POLL_PLT),
        0x910043FF,  # add sp,sp,#16
        cbz,         # cbz w0,skip
        0xAA1303E0,  # mov x0,x19
        0xD2800001,  # mov x1,#0
        bl_imm(CAVE + 88, READY_PLT),
        0xAA1403E0,  # skip: mov x0,x20
        0xF94013F5,  # ldr x21,[sp,#32]
        0xA94153F3,  # ldp x19,x20,[sp,#16]
        0xA8C37BFD,  # ldp x29,x30,[sp],#48
        0xD65F03C0,  # ret
    ]


pid, mu = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
site = u32(mem, mu + SITE)
cave0 = [u32(mem, mu + CAVE + 4 * i) for i in range(NWORDS)]
want = words()
want_site = bl_imm(SITE, CAVE)
print("pid", pid, "mu", hex(mu), "site", hex(site), "cave0", hex(cave0[0]))

if cmd == "status":
    poked = site == want_site and cave0 == want
    print("live", "poked" if poked else "stock-or-mixed")
elif cmd == "apply":
    if site == want_site and cave0 == want:
        print("already poked")
    else:
        if site != SITE_STOCK:
            raise SystemExit(f"18fe78 not stock bl attach: {site:#x}")
        if any(cave0):
            raise SystemExit(f"cave not empty: {[hex(x) for x in cave0[:8]]}")
        for i, w in enumerate(want):
            w32(mem, mu + CAVE + 4 * i, w)
        w32(mem, mu + SITE, want_site)
        print("poked site", hex(want_site), "words", [hex(x) for x in want])
elif cmd == "restore":
    w32(mem, mu + SITE, SITE_STOCK)
    for i in range(NWORDS):
        w32(mem, mu + CAVE + 4 * i, 0)
    print("restored site", hex(u32(mem, mu + SITE)))
mem.close()
print("tracing_on", Path("/sys/kernel/debug/tracing/tracing_on").read_text().strip())
PY
    ;;
  *)
    echo "usage: $0 status|apply|restore" >&2
    exit 2
    ;;
esac
