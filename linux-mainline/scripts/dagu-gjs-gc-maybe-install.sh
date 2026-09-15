#!/usr/bin/env bash
# Live-only: idle GC GSource JS_GC(reason=35/MEM_PRESSURE) → JS_MaybeGC.
# objdump of board libgjs.so.0.0.0:
#   0xa8648 mov w1,#0x23
#   0xa864c bl JS_GC@plt          stock 0x97fdf489
#   0xa864c bl JS_MaybeGC@plt     poke  0x97fdfc95
# Does not write the disk so. Does not restart gnome-shell.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

"${SSH[@]}" python3 - "$cmd" <<'PY'
import struct, pathlib, sys
cmd = sys.argv[1]
OFF = 0xa864c
STOCK = 0x97fdf489
POKE = 0x97fdfc95

def find():
    out = []
    for p in pathlib.Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            c = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if not c.startswith(b"/usr/bin/gnome-shell"):
            continue
        base = None
        for line in (p / "maps").read_text().splitlines():
            if "libgjs.so" in line and "r-xp" in line:
                base = int(line.split("-", 1)[0], 16)
                break
        if base is None:
            continue
        mem = open(p / "mem", "r+b", buffering=0)
        mem.seek(base + OFF)
        val = struct.unpack("<I", mem.read(4))[0]
        out.append((p.name, base, mem, val))
    return out

hits = find()
if not hits:
    raise SystemExit("no gnome-shell libgjs")
for pid, base, mem, val in hits:
    state = "poked" if val == POKE else ("stock" if val == STOCK else hex(val))
    print(f"pid={pid} base={base:#x} a864c={val:#x} {state}")
    if cmd == "apply-live" and val != POKE:
        mem.seek(base + OFF)
        mem.write(struct.pack("<I", POKE))
        mem.seek(base + OFF)
        now = struct.unpack("<I", mem.read(4))[0]
        print(f"  wrote {now:#x}")
    elif cmd == "restore-live" and val != STOCK:
        mem.seek(base + OFF)
        mem.write(struct.pack("<I", STOCK))
        mem.seek(base + OFF)
        now = struct.unpack("<I", mem.read(4))[0]
        print(f"  wrote {now:#x}")
    mem.close()
PY
