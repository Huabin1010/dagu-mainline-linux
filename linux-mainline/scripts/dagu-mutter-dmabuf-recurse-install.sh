#!/usr/bin/env bash
# REJECTED 2026-09-14: with ifn-iter this crashes gnome-shell (DmaBuf apply
# re-enters nview/ifn/iteration). Do not apply. Do not combine with
# dagu-mutter-ifn-iter-install.sh.
# DmaBuf GSource: g_source_set_can_recurse(src, TRUE) after g_source_new.
# Live 0x18ff40 mov x26,x0 → bl cave@0x1d1bd8. Does not touch 0x1d2b80 / 0x1c4388.
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
SITE = 0x18FF40
SITE_STOCK = 0xAA0003FA  # mov x26, x0
CAVE = 0x1D1BD8
RECURSE_OFF = 0x5EF20  # g_source_set_can_recurse


def find_ubuntu():
    mu = glib = None
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
            if "libglib-2.0.so" in line and "r-xp" in line:
                glib = int(line.split("-", 1)[0], 16)
        break
    if pid is None or mu is None or glib is None:
        raise SystemExit(f"need ubuntu+maps mu={mu} glib={glib}")
    return pid, mu, glib


def u32(mem, addr):
    mem.seek(addr)
    return struct.unpack("<I", mem.read(4))[0]


def w32(mem, addr, val):
    mem.seek(addr)
    mem.write(struct.pack("<I", val))


def bl_imm(pc, dest):
    return 0x94000000 | (((dest - pc) // 4) & 0x3FFFFFF)


def words(mu, glib):
    bl = bl_imm(mu + CAVE + 16, glib + RECURSE_OFF)
    return [
        0xAA0003FA,  # mov x26, x0
        0xA9BF7BFD,  # stp x29,x30,[sp,#-16]!
        0x910003FD,  # mov x29, sp
        0x52800021,  # mov w1, #1
        bl,          # bl g_source_set_can_recurse
        0xA8C17BFD,  # ldp x29,x30,[sp],#16
        0xD65F03C0,  # ret
    ]


pid, mu, glib = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
site = u32(mem, mu + SITE)
cave0 = [u32(mem, mu + CAVE + 4 * i) for i in range(7)]
want = words(mu, glib)
want_site = bl_imm(SITE, CAVE)
print("pid", pid, "mu", hex(mu), "glib", hex(glib), "site", hex(site), "cave0", hex(cave0[0]))

if cmd == "status":
    poked = site == want_site and cave0 == want
    print("live", "poked" if poked else "stock-or-mixed")
elif cmd == "apply":
    if site == want_site and cave0 == want:
        print("already poked")
    else:
        if site != SITE_STOCK:
            raise SystemExit(f"18ff40 not stock mov: {site:#x}")
        if any(cave0):
            raise SystemExit(f"cave not empty: {[hex(x) for x in cave0]}")
        for i, w in enumerate(want):
            w32(mem, mu + CAVE + 4 * i, w)
        w32(mem, mu + SITE, want_site)
        print("poked site", hex(want_site), "words", [hex(x) for x in want])
elif cmd == "restore":
    w32(mem, mu + SITE, SITE_STOCK)
    for i in range(7):
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
