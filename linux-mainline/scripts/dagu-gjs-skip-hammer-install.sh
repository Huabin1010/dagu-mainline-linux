#!/usr/bin/env bash
# Live-only: trigger_gc_if_needed always takes gjs_gc_if_needed, skip JS_GC(BIG_HAMMER).
# objdump libgjs.so.0.0.0:
#   0xa8644 tbz w1,#17,a8670   stock 0x36880161
#   0xa8644 b a8670            poke  0x1400000b
#   0xa864c remains bl JS_GC (unreached when poked)
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
OFF = 0xa8644
STOCK = 0x36880161
POKE = 0x1400000b

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
        if b"--mode=ubuntu" not in c:
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
        out.append((p.name, c.split(b"\x00")[0], base, mem, val))
    return out

hits = find()
if not hits:
    raise SystemExit("no gnome-shell libgjs")
for pid, cmd0, base, mem, val in hits:
    state = "poked" if val == POKE else ("stock" if val == STOCK else hex(val))
    print(f"pid={pid} base={base:#x} a8644={val:#x} {state}")
    do = None
    if cmd == "apply-live" and val != POKE:
        do = POKE
    elif cmd == "restore-live" and val != STOCK:
        do = STOCK
    if do is not None:
        mem.seek(base + OFF)
        mem.write(struct.pack("<I", do))
        mem.seek(base + OFF)
        now = struct.unpack("<I", mem.read(4))[0]
        print(f"  wrote {now:#x}")
    mem.close()
PY
