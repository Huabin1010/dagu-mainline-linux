#!/usr/bin/env bash
# emit_frame_callbacks: do not skip send_done when visibility check is 0.
# Live 0x1673c8 cbz w0,skip → nop. Pair with ifn-emit only after measuring.
# Does not write the disk so. usage: status|apply|restore
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
OFF = 0x1673C8
STOCK = 0x34000280  # cbz w0, 0x167418
POKE = 0xD503201F   # nop


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
got = struct.unpack("<I", mem.read(4))[0]
print("pid", pid, "base", hex(base), "1673c8", hex(got))
if cmd == "status":
    print("live", "poked" if got == POKE else ("stock" if got == STOCK else hex(got)))
elif cmd == "apply":
    if got != STOCK:
        raise SystemExit(f"1673c8 not stock: {got:#x}")
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", POKE))
    print("poked nop")
elif cmd == "restore":
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", STOCK))
    print("restored")
mem.close()
PY
    ;;
  *)
    echo "usage: $0 {status|apply|restore}" >&2
    exit 2
    ;;
esac
