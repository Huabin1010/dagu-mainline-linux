#!/usr/bin/env bash
# notify_presented DISPATCHED_ONE→IDLE: set pending_reschedule=1 before
# maybe_reschedule. Cave at 0x61e40. Live ubuntu only. Do not write disk so.
# Empty frames go notify_ready (not this path) so should not 120Hz-storm.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

"${SSH[@]}" python3 - "$cmd" <<'PY'
import pathlib, struct, sys
cmd = sys.argv[1]
SITE, CAVE, STOCK = 0x683d8, 0x61e40, 0xaa1303e0  # mov x0,x19
RET = 0x683dc  # bl maybe_reschedule


def b(pc, tgt):
    return 0x14000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


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
        for line in (p / "maps").read_text().splitlines():
            if "libmutter-clutter-18.so" in line and "r-xp" in line:
                return int(p.name), int(line.split("-", 1)[0], 16)
    raise SystemExit("no ubuntu gnome-shell clutter")


def assemble():
    words = []

    def here():
        return CAVE + 4 * len(words)

    words.append(0x52800020)  # mov w0,#1
    words.append(0xb9018e60)  # str w0,[x19,#396] pending (Rn=x19, not x3)
    words.append(0xaa1303e0)  # mov x0,x19
    words.append(b(here(), RET))
    return b"".join(struct.pack("<I", w) for w in words)


pid, base = find_ubuntu()
site_poke = b(SITE, CAVE)
blob = assemble()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(base + SITE)
cur = struct.unpack("<I", mem.read(4))[0]
print(f"pid={pid} base={base:#x} 683d8={cur:#x} poke={site_poke:#x}")
print("stock" if cur == STOCK else ("poked" if cur == site_poke else "mixed"))
if cmd == "apply-live":
    if cur != STOCK:
        raise SystemExit(f"refuse: not stock {cur:#x}")
    mem.seek(base + CAVE)
    mem.write(blob)
    mem.seek(base + SITE)
    mem.write(struct.pack("<I", site_poke))
    mem.seek(base + SITE)
    print("wrote site", hex(struct.unpack("<I", mem.read(4))[0]))
elif cmd == "restore-live":
    mem.seek(base + SITE)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(base + SITE)
    print("restored", hex(struct.unpack("<I", mem.read(4))[0]))
mem.close()
PY
