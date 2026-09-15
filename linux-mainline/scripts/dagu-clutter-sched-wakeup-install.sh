#!/usr/bin/env bash
# Live-only: after clutter_frame_clock_schedule_update set_ready_time,
# g_main_context_wakeup(source->context). Hole-pc shows shell in ppoll
# while ready_time=now (B-main 90ms). Cave at 0x61e40 (4080-byte zero gap).
# Does not write disk so. Does not restart gnome-shell.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

"${SSH[@]}" python3 - "$cmd" <<'PY'
import struct, pathlib, sys
cmd = sys.argv[1]
CAVE = 0x61e40
SITE1 = 0x67618  # bl set_ready_time
SITE2 = 0x67744  # b  set_ready_time (tail)
STOCK1 = 0x97ff0fde
STOCK2 = 0x17ff0f93
OFF_READY = 0x2b590
OFF_WAKE = 0x2a610


def bl(pc, tgt):
    return 0x94000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def b(pc, tgt):
    return 0x14000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def assemble():
    words = []

    def here():
        return CAVE + 4 * len(words)

    def emit(w):
        words.append(w & 0xFFFFFFFF)

    emit(0xa9bf7bf3)  # stp x19,x30,[sp,#-16]!
    emit(0xaa0003f3)  # mov x19,x0
    emit(bl(here(), OFF_READY))
    emit(0xf9404260)  # ldr x0,[x19,#128]
    emit(0xb4000040)  # cbz x0, +8
    emit(bl(here(), OFF_WAKE))
    emit(0xa8c17bf3)  # ldp x19,x30,[sp],#16
    emit(0xd65f03c0)  # ret
    return b"".join(struct.pack("<I", w) for w in words)


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
    raise SystemExit("no ubuntu clutter")


pid, base = find_ubuntu()
blob = assemble()
s1 = bl(SITE1, CAVE)
s2 = b(SITE2, CAVE)
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(base + SITE1)
c1 = struct.unpack("<I", mem.read(4))[0]
mem.seek(base + SITE2)
c2 = struct.unpack("<I", mem.read(4))[0]
print(f"pid={pid} clutter={base:#x} 67618={c1:#x} 67744={c2:#x} s1={s1:#x} s2={s2:#x}")
if cmd == "apply-live":
    if c1 not in (STOCK1, s1) or c2 not in (STOCK2, s2):
        raise SystemExit(f"unexpected {c1:#x} {c2:#x}")
    mem.seek(base + CAVE)
    mem.write(blob)
    mem.seek(base + SITE1)
    mem.write(struct.pack("<I", s1))
    mem.seek(base + SITE2)
    mem.write(struct.pack("<I", s2))
    mem.seek(base + SITE1)
    print("wrote", hex(struct.unpack("<I", mem.read(4))[0]))
elif cmd == "restore-live":
    mem.seek(base + SITE1)
    mem.write(struct.pack("<I", STOCK1))
    mem.seek(base + SITE2)
    mem.write(struct.pack("<I", STOCK2))
    print("restored sites")
else:
    poked = c1 == s1 and c2 == s2
    stock = c1 == STOCK1 and c2 == STOCK2
    print("poked" if poked else ("stock" if stock else "mixed"))
mem.close()
PY
