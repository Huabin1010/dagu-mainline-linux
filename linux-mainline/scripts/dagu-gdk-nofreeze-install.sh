#!/usr/bin/env bash
# REJECTED 2026-09-14: skip GDK after_paint freeze.
# 8s kickoff 81.49 Hz / gt50=27 (unthrottled commit destile). Restored.
# Do not apply. Live lab only; do not write disk so.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

"${SSH[@]}" python3 - "$cmd" <<'PY'
import pathlib, struct, sys
cmd = sys.argv[1]
OFF, STOCK, POKE = 0x518cc8, 0xb40000c0, 0x14000006  # cbz → b ret


def find_lab():
    for p in pathlib.Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            c = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if b"dagu-native-lab.py" not in c:
            continue
        if not c.startswith(b"python"):
            continue
        for line in (p / "maps").read_text().splitlines():
            if "libgtk-4.so" in line and "r-xp" in line:
                return int(p.name), int(line.split("-", 1)[0], 16)
    raise SystemExit("no identity lab libgtk-4")


pid, base = find_lab()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(base + OFF)
cur = struct.unpack("<I", mem.read(4))[0]
print(f"pid={pid} gtk={base:#x} 518cc8={cur:#x}")
print("stock" if cur == STOCK else ("poked" if cur == POKE else "mixed"))
if cmd == "apply-live":
    if cur != STOCK:
        raise SystemExit(f"refuse: not stock {cur:#x}")
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", POKE))
    mem.seek(base + OFF)
    print("wrote", hex(struct.unpack("<I", mem.read(4))[0]))
elif cmd == "restore-live":
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(base + OFF)
    print("restored", hex(struct.unpack("<I", mem.read(4))[0]))
mem.close()
PY
