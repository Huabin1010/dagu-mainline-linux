#!/usr/bin/env bash
# REJECTED 2026-09-14: apply-live on 475152, gnome-shell gone (~1s),
# GDM reopened 479005. Same class as state9-now (b.eq 0x67604):
# DISPATCHED_TWO 上强改 SCHEDULED 会三缓冲重入崩溃。不要再 apply.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

"${SSH[@]}" python3 - "$cmd" <<'PY'
import pathlib, struct, sys
cmd = sys.argv[1]
SITE, CAVE, STOCK = 0x67648, 0x61e40, 0x540003a1
RET = 0x67654
GET_TIME = 0x2b4b0
SET_READY = 0x2b590


def bl(pc, tgt):
    return 0x94000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def b(pc, tgt):
    return 0x14000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def bcond(pc, tgt, cond):
    return 0x54000000 | ((((tgt - pc) // 4) & 0x7FFFF) << 5) | cond


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


def assemble():
    words = []
    def here():
        return CAVE + 4 * len(words)
    # str x5,[sp,#8]
    words.append(0xf90007e5)
    # bl g_get_monotonic_time
    words.append(bl(here(), GET_TIME))
    # ldr x5,[sp,#8]
    words.append(0xf94007e5)
    # mov x1,x0
    words.append(0xaa0003e1)
    # ldr x0,[x5,#72]
    words.append(0xf94024a0)
    # bl g_source_set_ready_time
    words.append(bl(here(), SET_READY))
    # mov w0,#2
    words.append(0x52800040)
    # str w0,[x5,#88]
    words.append(0xb90058a0)
    # b epilogue
    words.append(b(here(), RET))
    return b"".join(struct.pack("<I", w) for w in words)


pid, base = find_ubuntu()
site_poke = bcond(SITE, CAVE, 0)  # b.eq cave
blob = assemble()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(base + SITE)
cur = struct.unpack("<I", mem.read(4))[0]
print(f"pid={pid} base={base:#x} 67648={cur:#x} site_eq={site_poke:#x}")
print("stock" if cur == STOCK else ("poked" if cur == site_poke else "mixed"))
if cmd == "apply-live":
    if cur != STOCK:
        raise SystemExit(f"refuse: not stock {cur:#x}")
    mem.seek(base + CAVE)
    mem.write(blob)
    mem.seek(base + SITE)
    mem.write(struct.pack("<I", site_poke))
    mem.seek(base + SITE)
    print("wrote site", hex(struct.unpack("<I", mem.read(4))[0]))
elif cmd == "restore-live":
    mem.seek(base + SITE)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(base + SITE)
    print("restored", hex(struct.unpack("<I", mem.read(4))[0]))
mem.close()
PY
