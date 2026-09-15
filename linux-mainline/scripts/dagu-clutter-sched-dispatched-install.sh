#!/usr/bin/env bash
# schedule_update: state==DISPATCHED_TWO (9) currently only sets
# pending_reschedule and ret. GTK apply after after_update hits this,
# ready_time stays -1 until a present that never comes.
# 0x67648 b.ne 0x676bc → b 0x676bc (state 9 also computes set_ready_time).
# REJECTED 2026-09-14: apply-live on ubuntu 468357, 8s kickoff 113.7Hz
# gt50=2, fcdisp 208682 (empty dispatch storm). Restored. Do not apply.
# Live ubuntu gnome-shell only. Do not write disk so.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

"${SSH[@]}" python3 - "$cmd" <<'PY'
import pathlib, struct, sys
cmd = sys.argv[1]
OFF, STOCK, POKE = 0x67648, 0x540003a1, 0x1400001d


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


pid, base = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(base + OFF)
cur = struct.unpack("<I", mem.read(4))[0]
print(f"pid={pid} base={base:#x} 67648={cur:#x}",
      "stock" if cur == STOCK else ("poked" if cur == POKE else "mixed"))
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
