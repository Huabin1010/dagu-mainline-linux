#!/usr/bin/env bash
# add_page_flip_listener(..., NULL) → default, so nview waits on the
# blocked main loop. Live-only: pass the KMS impl GMainContext instead.
# 0x1c2230 mov x3,#0 → bl cave@0x1d2b80. Cave empty on restore.
# Does not write the disk so. Does not restart gdm.
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
SITE = 0x1C2230
SITE_STOCK = 0xD2800003  # mov x3,#0
CAVE = 0x1D2B80
GET_DEV = 0x1AA7C4
GET_KMS = 0x1AA948
DEFCTX = 0x62290
QUARK_PAGE = 0x2B5000
QUARK_OFF = 2280


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
                base = int(line.split("-", 1)[0], 16)
                return int(p.name), base
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
        raise SystemExit(f"bl out of range {pc:#x}->{tgt:#x}")
    return 0x94000000 | (imm & 0x03FFFFFF)


def adrp(pc, tgt_page, rd):
    page = tgt_page & ~0xFFF
    pc_page = pc & ~0xFFF
    imm = (page - pc_page) >> 12
    immlo = imm & 3
    immhi = (imm >> 2) & 0x7FFFF
    return 0x90000000 | (immlo << 29) | (immhi << 5) | rd


pid, base = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
site = u32(mem, base + SITE)
cave0 = u32(mem, base + CAVE)
print(f"shell={pid} base={base:#x} site={site:08x} cave0={cave0:08x}")

if cmd == "status":
    raise SystemExit(0)

if cmd == "restore":
    if site != SITE_STOCK:
        if (site & 0xFC000000) != 0x94000000:
            raise SystemExit(f"refuse restore, site {site:08x}")
        w32(mem, base + SITE, SITE_STOCK)
    for i in range(20):
        w32(mem, base + CAVE + 4 * i, 0)
    mem.flush()
    print("restored", f"{u32(mem, base+SITE):08x}", f"{u32(mem, base+CAVE):08x}")
    raise SystemExit(0)

if site != SITE_STOCK:
    raise SystemExit(f"refuse apply, site {site:08x} not stock mov x3,#0")
if cave0 != 0:
    raise SystemExit(f"refuse apply, cave occupied {cave0:08x}")

# cave: x1=crtc in, x3=kms context out; preserve x0,x1,x2,x4,x5
ins = [
    0xD503233F,              # paciasp
    0xA9BC7BFD,              # stp x29,x30,[sp,#-64]!
    0x910003FD,              # mov x29,sp
    0xA90107E0,              # stp x0,x1,[sp,#16]
    0xA90213E2,              # stp x2,x4,[sp,#32]
    0xF9001BE5,              # str x5,[sp,#48]
    0xAA0103E0,              # mov x0,x1
]
pc = CAVE + 4 * len(ins)
ins.append(bl_imm(pc, GET_DEV))
pc = CAVE + 4 * len(ins)
ins.append(bl_imm(pc, GET_KMS))
pc = CAVE + 4 * len(ins)
ins.append(adrp(pc, QUARK_PAGE, 1))
ins += [
    0xB988E821,              # ldrsw x1,[x1,#2280]
    0x8B010000,              # add x0,x0,x1
    0xF9400C00,              # ldr x0,[x0,#24] impl
    0xF9400C03,              # ldr x3,[x0,#24] context
    0xB4000043,              # cbz x3, +8 (skip default)
]
# if context NULL, call g_main_context_default into x3
pc = CAVE + 4 * (len(ins) + 0)
# cbz already skips one insn; we'll append bl default then continue
# rewrite last: if non-null skip the bl default
# currently: cbz x3, +8 means skip next 1 insn. Put bl default as next.
pc = CAVE + 4 * len(ins)
ins.append(bl_imm(pc, DEFCTX))  # x0=default; only reached if x3==0? WAIT
# cbz x3, +8 skips ONE instruction (the bl). If x3!=0 we skip bl. If x3==0 we bl default.
# but bl default writes x0, not x3. Need mov x3,x0 after.
# cbz +8 only skips one insn. Use cbz to skip two:
#   cbnz x3, 1f
#   bl default
#   mov x3, x0
# 1: restore
# Replace cbz with cbnz to restore path.

ins[-1] = 0xB5000063  # cbnz x3, +12 (skip bl+mov)
pc = CAVE + 4 * len(ins)
ins.append(bl_imm(pc, DEFCTX))
ins.append(0xAA0003E3)          # mov x3,x0
ins += [
    0xA94107E0,              # ldp x0,x1,[sp,#16]
    0xA94213E2,              # ldp x2,x4,[sp,#32]
    0xF9401BE5,              # ldr x5,[sp,#48]
    0xA8C47BFD,              # ldp x29,x30,[sp],#64
    0xD50323BF,              # autiasp
    0xD65F03C0,              # ret
]

if len(ins) > 24:
    raise SystemExit(f"cave too long {len(ins)}")
# 0x1d2be0 is the next real function; 24 insns end at 0x1d2be0.
for i, w in enumerate(ins):
    w32(mem, base + CAVE + 4 * i, w)
w32(mem, base + SITE, bl_imm(SITE, CAVE))
mem.flush()
print("applied", f"{u32(mem, base+SITE):08x}", "cave", [f"{u32(mem, base+CAVE+4*i):08x}" for i in range(len(ins))])
PY
    ;;
  *)
    echo "usage: $0 status|apply|restore" >&2
    exit 1
    ;;
esac
