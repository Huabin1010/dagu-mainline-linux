#!/usr/bin/env bash
# flipped_in_impl warning path: post_impl_task(get_onscreen+promote+ifgl).
# Does NOT call ifgl inside the flip handler (that reentered atomic, 113 Hz).
# Does NOT call notify_complete (KMS nview killed kickoff).
# 0x1bd348 ldr x1,[x20,#8] → bl cave@0x1d2b80. Live only.
# listener+32 is the stage view; task does get_onscreen@plt.
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
SITE = 0x1BD348
SITE_STOCK = 0xF9400681  # ldr x1,[x20,#8]
CAVE = 0x1D2B80
PROMOTE = 0x1C1220
IFGL = 0x1C4380
GET_ONS = 0x62850
POST = 0x1D7500
TASK = CAVE + 12 * 4


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


def u32(mem, addr):
    mem.seek(addr)
    return struct.unpack("<I", mem.read(4))[0]


def w32(mem, addr, val):
    mem.seek(addr)
    mem.write(struct.pack("<I", val))


def bl_imm(pc, tgt):
    imm = (tgt - pc) // 4
    if not (-2**25 <= imm < 2**25):
        raise SystemExit(f"bl range {pc:#x}->{tgt:#x}")
    return 0x94000000 | (imm & 0x03FFFFFF)


def cbz_x(rt, pc, tgt):
    imm19 = (tgt - pc) // 4
    if not (-2**18 <= imm19 < 2**18):
        raise SystemExit(f"cbz range {pc:#x}->{tgt:#x}")
    return 0xB4000000 | ((imm19 & 0x7FFFF) << 5) | (rt & 31)


def adr_x(rd, pc, tgt):
    imm = tgt - pc
    if imm & 3:
        raise SystemExit(f"adr unaligned {imm}")
    if not (-2**20 <= imm < 2**20):
        raise SystemExit(f"adr range {pc:#x}->{tgt:#x}")
    immlo = imm & 3
    immhi = (imm >> 2) & 0x7FFFF
    return 0x10000000 | (immlo << 29) | (immhi << 5) | rd


pid, base = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
site = u32(mem, base + SITE)
cave0 = u32(mem, base + CAVE)
print(f"shell={pid} site={site:08x} cave0={cave0:08x}")

if cmd == "status":
    raise SystemExit(0)

if cmd == "restore":
    if site != SITE_STOCK:
        if (site & 0xFC000000) != 0x94000000:
            raise SystemExit(f"refuse restore {site:08x}")
        w32(mem, base + SITE, SITE_STOCK)
    for i in range(24):
        w32(mem, base + CAVE + 4 * i, 0)
    mem.flush()
    print("restored", f"{u32(mem, base+SITE):08x}", f"{u32(mem, base+CAVE):08x}")
    raise SystemExit(0)

if site != SITE_STOCK:
    raise SystemExit(f"refuse apply site {site:08x}")
if cave0 != 0:
    raise SystemExit(f"refuse apply cave {cave0:08x}")

# entry 0-11: post_impl_task(kms=x22, func=task, user=view); ldr x1,[x20,#8]; ret
# task  12-23: get_onscreen(view); promote; ifgl; ret
LDP = CAVE + 9 * 4
ins = [
    0xA9BF7BFD,  # stp x29,x30,[sp,#-16]!
    0xF9401282,  # ldr x2,[x20,#32] view
    cbz_x(2, CAVE + 2 * 4, LDP),
    0xAA1603E0,  # mov x0,x22  kms
    adr_x(1, CAVE + 4 * 4, TASK),
    0xD2800003,  # mov x3,#0
    0xD2800004,  # mov x4,#0
    0xD2800005,  # mov x5,#0
    bl_imm(CAVE + 8 * 4, POST),
    0xA8C17BFD,  # ldp x29,x30,[sp],#16
    0xF9400681,  # ldr x1,[x20,#8]
    0xD65F03C0,  # ret
]
TOUT = TASK + 10 * 4
ins += [
    0xA9BE7BFD,  # stp x29,x30,[sp,#-32]!
    0xF9000BE1,  # str x1,[sp,#16] view
    0xAA0103E0,  # mov x0,x1
    cbz_x(0, TASK + 3 * 4, TOUT),
    bl_imm(TASK + 4 * 4, GET_ONS),
    cbz_x(0, TASK + 5 * 4, TOUT),
    bl_imm(TASK + 6 * 4, PROMOTE),
    0xF9400BE0,  # ldr x0,[sp,#16]
    bl_imm(TASK + 8 * 4, GET_ONS),
    bl_imm(TASK + 9 * 4, IFGL),
    0xA8C27BFD,  # ldp x29,x30,[sp],#32
    0xD65F03C0,  # ret
]
if len(ins) != 24:
    raise SystemExit(f"cave len {len(ins)}")
for i, w in enumerate(ins):
    w32(mem, base + CAVE + 4 * i, w)
w32(mem, base + SITE, bl_imm(SITE, CAVE))
mem.flush()
print("applied", f"{u32(mem, base+SITE):08x}", "nins", len(ins), "task", hex(TASK))
PY
    ;;
  *)
    echo "usage: $0 status|apply|restore" >&2
    exit 1
    ;;
esac
