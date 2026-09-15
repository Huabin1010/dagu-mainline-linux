#!/usr/bin/env bash
# ifgl next==NULL: g_main_context_iteration(NULL, FALSE) then ret.
# Live 0x1c4388 cbz x1,0x1c4404 → cbz x1,cave@0x1d2b80.
# Does not write 0x1c4404 (must stay ret). Does not write the disk so.
# Never uprobe 0x1c4388 while poked: uninstall writes file bytes back.
# Never combine with dagu-mutter-dmabuf-recurse-install.sh (crashes shell).
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
SITE = 0x1C4388
SITE_STOCK = 0xB40003E1  # cbz x1, 0x1c4404
CAVE = 0x1D2B80
RET = 0x1C4404
RET_STOCK = 0xD65F03C0
ITER_OFF = 0x61E08  # g_main_context_iteration in libglib-2.0.so.0.8800.0


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


def cbz_x1(pc, dest):
    imm19 = ((dest - pc) // 4) & 0x7FFFF
    return 0xB4000001 | (imm19 << 5)


def bl_imm(pc, dest):
    imm26 = ((dest - pc) // 4) & 0x3FFFFFF
    return 0x94000000 | imm26


def words(mu, glib):
    bl = bl_imm(mu + CAVE + 16, glib + ITER_OFF)
    return [
        0xA9BF7BFD,  # stp x29,x30,[sp,#-16]!
        0x910003FD,  # mov x29,sp
        0xD2800000,  # mov x0,#0
        0x52800001,  # mov w1,#0
        bl,          # bl g_main_context_iteration
        0xA8C17BFD,  # ldp x29,x30,[sp],#16
        0xD65F03C0,  # ret
    ]


pid, mu, glib = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
site = u32(mem, mu + SITE)
ret = u32(mem, mu + RET)
cave0 = [u32(mem, mu + CAVE + 4 * i) for i in range(7)]
want = words(mu, glib)
want_site = cbz_x1(SITE, CAVE)
print(
    "pid", pid, "mu", hex(mu), "glib", hex(glib),
    "site", hex(site), "ret", hex(ret), "cave0", hex(cave0[0]),
)

if cmd == "status":
    poked = site == want_site and cave0 == want and ret == RET_STOCK
    print("live", "poked" if poked else "stock-or-mixed")
elif cmd == "apply":
    if site == want_site and cave0 == want:
        print("already poked")
    else:
        if site != SITE_STOCK:
            raise SystemExit(f"1c4388 not stock cbz: {site:#x}")
        if ret != RET_STOCK:
            raise SystemExit(f"1c4404 not stock ret: {ret:#x}")
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
    print("restored site", hex(u32(mem, mu + SITE)), "ret", hex(u32(mem, mu + RET)))
mem.close()
print("tracing_on", Path("/sys/kernel/debug/tracing/tracing_on").read_text().strip())
PY
    ;;
  *)
    echo "usage: $0 status|apply|restore" >&2
    exit 2
    ;;
esac
