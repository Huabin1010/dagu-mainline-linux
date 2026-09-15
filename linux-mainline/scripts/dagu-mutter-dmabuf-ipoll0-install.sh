#!/usr/bin/env bash
# Implicit dma-buf g_poll==0: treat as ready (skip DmaBuf readiness GSource).
# Live 0x18fdbc cbz w0,0x18fdd0 → cbz w0,0x18fe4c.
# Does not write the disk so. Does not touch 0x1bd9d8 KMS infence skip-poll.
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
OFF = 0x18FDBC
STOCK = 0x340000A0  # cbz w0, 0x18fdd0
POKE = 0x34000480   # cbz w0, 0x18fe4c

SITES = {
    0x18FDBC: (STOCK, POKE, "ipoll0"),
    0x1C4404: (0xD65F03C0, None, "ifn-ret"),
    0x1BD9D8: (0x1400000A, None, "infence-skip"),  # b 0x1bda00
    0x1C2230: (0xD2800003, None, "mov-x3-0"),
}


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
print("pid", pid, "base", hex(base))
for off, (stock, poke, name) in SITES.items():
    mem.seek(base + off)
    got = struct.unpack("<I", mem.read(4))[0]
    mark = "poked" if poke is not None and got == poke else (
        "stock" if got == stock else f"other {got:#x}"
    )
    print(f"  {name} {off:#x} {got:#x} {mark}")

cave = mem.read(0)  # keep linter quiet
mem.seek(base + 0x1D2B80)
cave = mem.read(16)
print("  cave 0x1d2b80", cave.hex(), "empty" if cave == b"\x00" * 16 else "NONEMPTY")

if cmd == "status":
    pass
elif cmd == "apply":
    mem.seek(base + OFF)
    got = struct.unpack("<I", mem.read(4))[0]
    if got != STOCK:
        raise SystemExit(f"18fdbc not stock: {got:#x}")
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", POKE))
    mem.seek(base + OFF)
    got = struct.unpack("<I", mem.read(4))[0]
    print("poked 18fdbc", hex(got))
elif cmd == "restore":
    mem.seek(base + OFF)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(base + OFF)
    got = struct.unpack("<I", mem.read(4))[0]
    print("restored 18fdbc", hex(got))
mem.close()
PY
    ;;
  *)
    echo "usage: $0 {status|apply|restore}" >&2
    exit 2
    ;;
esac
