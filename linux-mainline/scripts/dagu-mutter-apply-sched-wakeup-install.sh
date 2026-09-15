#!/usr/bin/env bash
# apply_state (0x16517c): after clutter_stage_schedule_update, also
# g_main_context_wakeup(NULL). Only the Wayland commit path — not every
# frame-clock set_ready_time (that destiled, see sched-wakeup).
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
import struct, sys
from pathlib import Path

cmd = sys.argv[1]
SITE = 0x16517C
STOCK = 0x97FC047D  # bl clutter_stage_schedule_update@plt 0x66374
CAVE = 0x1D2B80
SCHED_PLT = 0x66374
WAKE_PLT = 0x68450


def bl(pc, tgt):
    return 0x94000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


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


def words():
    # 1d2b80 str x30,[sp,#-16]!
    # 1d2b84 bl schedule_update@plt
    # 1d2b88 mov x0,#0
    # 1d2b8c bl wakeup@plt
    # 1d2b90 ldr x30,[sp],#16
    # 1d2b94 ret
    return [
        0xF81F0FFE,
        bl(CAVE + 4, SCHED_PLT),
        0xD2800000,
        bl(CAVE + 12, WAKE_PLT),
        0xF84107FE,
        0xD65F03C0,
    ]


pid, base = find_ubuntu()
want = words()
poke = bl(SITE, CAVE)
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(base + SITE)
cur = struct.unpack("<I", mem.read(4))[0]
cave = [struct.unpack("<I", mem.read(4))[0] for _ in [mem.seek(base + CAVE) or 0] for i in range(6)]
# re-read cave properly
mem.seek(base + CAVE)
cave = [struct.unpack("<I", mem.read(4))[0] for _ in range(6)]
print(f"pid={pid} mutter={base:#x} 16517c={cur:#x} poke={poke:#x}")
print("cave", [hex(x) for x in cave])
print("stock" if cur == STOCK else ("poked" if cur == poke else "mixed"))
if cmd == "apply":
    if cur != STOCK:
        raise SystemExit(f"refuse: not stock {cur:#x}")
    if any(cave):
        raise SystemExit(f"cave not empty: {[hex(x) for x in cave]}")
    mem.seek(base + CAVE)
    for w in want:
        mem.write(struct.pack("<I", w))
    mem.seek(base + SITE)
    mem.write(struct.pack("<I", poke))
    mem.seek(base + SITE)
    print("wrote", hex(struct.unpack("<I", mem.read(4))[0]))
elif cmd == "restore":
    mem.seek(base + SITE)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(base + CAVE)
    mem.write(b"\x00" * 24)
    mem.seek(base + SITE)
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
