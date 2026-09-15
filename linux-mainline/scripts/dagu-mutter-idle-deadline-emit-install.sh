#!/usr/bin/env bash
# REJECTED 2026-09-14: 105.86 Hz / gt50=9 / max 208.5. Restored.
# after_update IDLE + future deadline: emit now instead of arming 0x167440.
# Do not apply. Live ubuntu only. Does not write the disk so.
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
OFF = 0x16968C
STOCK = 0xAA1303E0  # mov x0,x19  (g_source_get_ready_time)
# b 0x1696ac emit_now: (0x1696ac-0x16968c)/4 = 8
POKE = 0x14000008


def find_ubuntu():
    for p in Path("/proc").iterdir():
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
    raise SystemExit("no ubuntu gnome-shell")


pid, base = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(base + OFF)
cur = struct.unpack("<I", mem.read(4))[0]
print(f"pid={pid} mutter={base:#x} 16968c={cur:#x}")
print("stock" if cur == STOCK else ("poked" if cur == POKE else "mixed"))
if cmd == "apply":
    if cur != STOCK:
        raise SystemExit(f"refuse: not stock {cur:#x}")
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", POKE))
    mem.seek(base + OFF)
    print("wrote", hex(struct.unpack("<I", mem.read(4))[0]))
elif cmd == "restore":
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(base + OFF)
    print("restored", hex(struct.unpack("<I", mem.read(4))[0]))
mem.close()
print("tracing_on", Path("/sys/kernel/debug/tracing/tracing_on").read_text().strip())
print("kickoff", Path("/sys/kernel/debug/tracing/events/dpu/dpu_enc_kickoff/enable").read_text().strip())
PY
    ;;
  *)
    echo "usage: $0 status|apply|restore" >&2
    exit 2
    ;;
esac
