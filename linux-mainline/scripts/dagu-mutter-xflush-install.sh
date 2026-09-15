#!/usr/bin/env bash
# Live-only: NOP XFlush in X11 GSource prepare (libmutter 0x125400).
# Freeze BT 20260914-023606: B-main 113ms in XFlush→recvmsg.
# Sibling check @0x12543c already does XEventsQueued without flush.
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
OFF = 0x125400
STOCK = 0x97fd0b1c  # bl XFlush@plt
POKE = 0xd503201f   # nop


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
            if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
                return int(p.name), int(line.split("-", 1)[0], 16)
    raise SystemExit("no ubuntu gnome-shell mutter")


pid, base = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(base + OFF)
cur = struct.unpack("<I", mem.read(4))[0]
print(f"pid={pid} mutter={base:#x} 125400={cur:#x}")
if cmd == "apply-live":
    if cur not in (STOCK, POKE):
        raise SystemExit(f"unexpected insn {cur:#x}")
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", POKE))
    mem.seek(base + OFF)
    print("wrote", hex(struct.unpack("<I", mem.read(4))[0]))
elif cmd == "restore-live":
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(base + OFF)
    print("restored", hex(struct.unpack("<I", mem.read(4))[0]))
else:
    print("stock" if cur == STOCK else ("poked" if cur == POKE else hex(cur)))
mem.close()
PY
