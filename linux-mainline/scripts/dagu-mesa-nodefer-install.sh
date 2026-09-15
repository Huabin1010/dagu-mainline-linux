#!/usr/bin/env bash
# Lab-only: never defer Freedreno submits (fd_submit_sp_flush).
# Live libgallium 0xca15d0 cbnz w0,0xca1664 → b 0xca1664.
# File/live opcode 0x350004a0. Does not write the disk so.
# Does not touch mutter / gnome-shell.
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
OFF = 0xCA15D0
STOCK = 0x350004A0  # cbnz w0, 0xca1664
POKE = 0x14000025   # b 0xca1664


def find_lab():
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            c = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if not (c.startswith(b"python") and b"dagu-native-lab.py" in c and b"--video" in c):
            continue
        for line in (p / "maps").read_text().splitlines():
            if "libgallium-26.0.8-1ubuntu0.3.so" in line and "r-xp" in line:
                return int(p.name), int(line.split("-", 1)[0], 16)
    raise SystemExit("no identity lab gallium")


pid, base = find_lab()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(base + OFF)
got = struct.unpack("<I", mem.read(4))[0]
mark = "poked" if got == POKE else ("stock" if got == STOCK else f"other {got:#x}")
print("lab", pid, "gallium", hex(base), f"0xca15d0 {got:#x} {mark}")

if cmd == "status":
    pass
elif cmd == "apply":
    if got != STOCK:
        raise SystemExit(f"0xca15d0 not stock: {got:#x}")
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", POKE))
    mem.seek(base + OFF)
    got = struct.unpack("<I", mem.read(4))[0]
    print("poked 0xca15d0", hex(got))
elif cmd == "restore":
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(base + OFF)
    got = struct.unpack("<I", mem.read(4))[0]
    print("restored 0xca15d0", hex(got))
mem.close()
PY
    ;;
  *)
    echo "usage: $0 status|apply|restore" >&2
    exit 2
    ;;
esac
