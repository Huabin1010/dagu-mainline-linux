#!/usr/bin/env bash
# REJECTED 2026-09-14: 113.33 Hz / gt50=4, vblank 117/gt50=3. Restore.
# After DmaBuf g_source_attach: ALWAYS set_ready_time(src,0) then wakeup(NULL).
# Not POLLIN-gated (rdyt0 already rejected). Does not iterate / can_recurse.
# Live 0x18fe78 bl attach → bl cave@0x1d1bd8.
# Does not touch 0x1d2b80 / 0x1c4388 / 0x18ff40 / 0x18fdbc.
# Never uprobe 0x18fe78 while poked. Does not write the disk so.
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
READY_PLT = 0x675E0
WAKEUP_PLT = 0x68450
NWORDS = 15


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
    return [
        0xA9BE7BFD,  # stp x29,x30,[sp,#-32]!
        0x910003FD,  # mov x29,sp
        0xA90153F3,  # stp x19,x20,[sp,#16]
        0xAA0003F3,  # mov x19,x0
        bl_imm(CAVE + 16, ATTACH_PLT),
        0xAA0003F4,  # mov x20,x0
        0xAA1303E0,  # mov x0,x19
        0xD2800001,  # mov x1,#0
        bl_imm(CAVE + 32, READY_PLT),
        0xD2800000,  # mov x0,#0
        bl_imm(CAVE + 40, WAKEUP_PLT),
        0xAA1403E0,  # mov x0,x20
        0xA94153F3,  # ldp x19,x20,[sp,#16]
        0xA8C27BFD,  # ldp x29,x30,[sp],#32
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
        print("poked site", hex(want_site))
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
