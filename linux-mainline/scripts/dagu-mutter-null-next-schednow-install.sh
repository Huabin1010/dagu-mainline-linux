#!/usr/bin/env bash
# ifgl next==NULL (0x1c4404): schedule_update_now(view), not emit.
# Live ubuntu only. Cave 0x1d2b80. Does not write the disk so.
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
import os, struct, sys
from pathlib import Path

cmd = sys.argv[1]
CAVE = 0x1D2B80
BR = 0x1C4404
BR_STOCK = 0xD65F03C0
PLT = 0x629F0  # clutter_stage_view_schedule_update_now@plt
VIEW_OFF = 136


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
        maps = (p / "maps").read_text()
        base = None
        for line in maps.splitlines():
            if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
                base = int(line.split("-", 1)[0], 16)
                break
        if base is None:
            continue
        return int(p.name), base
    raise SystemExit("no ubuntu gnome-shell")


def u32(mem, addr):
    mem.seek(addr)
    return struct.unpack("<I", mem.read(4))[0]


def w32(mem, addr, val):
    mem.seek(addr)
    mem.write(struct.pack("<I", val))


def words():
    # 1d2b80: str x30,[sp,#-16]!
    # 1d2b84: ldr x0,[x0,#136]
    # 1d2b88: cbz x0, 1d2b98
    # 1d2b8c: bl schedule_update_now@plt
    # 1d2b90: ldr x30,[sp],#16
    # 1d2b94: ret
    # 1d2b98: ldr x30,[sp],#16
    # 1d2b9c: ret
    bl_pc = CAVE + 12
    imm26 = ((PLT - bl_pc) // 4) & 0x3FFFFFF
    ldr = 0xF9400000 | ((VIEW_OFF // 8) << 10)
    return [
        0xF81F0FFE,
        ldr,
        0xB4000080,
        0x94000000 | imm26,
        0xF84107FE,
        0xD65F03C0,
        0xF84107FE,
        0xD65F03C0,
    ]


def br_word():
    return 0x14000000 | (((CAVE - BR) // 4) & 0x3FFFFFF)


pid, base = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
br = u32(mem, base + BR)
cave0 = [u32(mem, base + CAVE + 4 * i) for i in range(8)]
want = words()
print("pid", pid, "base", hex(base), "br", hex(br), "cave0", hex(cave0[0]))

if cmd == "status":
    poked = br == br_word() and cave0 == want
    print("live", "poked" if poked else "stock-or-mixed")
elif cmd == "apply":
    if br == br_word() and cave0 == want:
        print("already poked")
    else:
        if br != BR_STOCK:
            raise SystemExit(f"1c4404 not stock ret: {br:#x}")
        if any(cave0):
            raise SystemExit(f"cave not empty: {[hex(x) for x in cave0]}")
        for i, w in enumerate(want):
            w32(mem, base + CAVE + 4 * i, w)
        w32(mem, base + BR, br_word())
        print("poked", "br", hex(br_word()), "words", [hex(x) for x in want])
elif cmd == "restore":
    w32(mem, base + BR, BR_STOCK)
    for i in range(8):
        w32(mem, base + CAVE + 4 * i, 0)
    print("restored")
mem.close()
print("tracing_on", Path("/sys/kernel/debug/tracing/tracing_on").read_text().strip())
PY
    ;;
  *)
    echo "usage: $0 {status|apply|restore}" >&2
    exit 2
    ;;
esac
