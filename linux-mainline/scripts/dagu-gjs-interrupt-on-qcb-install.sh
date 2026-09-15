#!/usr/bin/env bash
# REJECTED 2026-09-14: apply-live on ubuntu 486179 instantly killed the
# session (gdm autologin → new gnome-shell 561579). Do not apply.
# Live-only: after wakeup cave, request JS interrupt so MEM_PRESSURE JS_GC
# can yield when flip qcb hits default. Not MaybeGC / skip-hammer / inc-slice.
# objdump:
#   gjs  gjs_context_get_current loads [libgjs+0x1a0fc0]
#   gjs  GjsContext+16 = JSContext (trigger 0xa863c / native_context)
#   mozjs JS_RequestInterruptCallback @ 0x44f780
#   mutter 0x1d6f28 ret → b cave 0x1d2b80
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
CAVE = 0x1d2b80
SITE = 0x1d6f28
STOCK_RET = 0xd65f03c0
GJS_CUR = 0x1a0fc0
MOZ_IRQ = 0x44f780


def b_imm(pc, tgt):
    return 0x14000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


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
        mu = gjs = moz = None
        for line in (p / "maps").read_text().splitlines():
            if "r-xp" not in line:
                continue
            lo = int(line.split("-", 1)[0], 16)
            if "libmutter-18.so.0.0.0" in line and "mutter-18/" not in line:
                mu = lo
            elif "libgjs.so" in line:
                gjs = lo
            elif "libmozjs-140" in line:
                moz = lo
        if mu and gjs and moz:
            return int(p.name), mu, gjs, moz
    raise SystemExit("no ubuntu gnome-shell maps")


def ldr_lit(rt, pc, tgt):
    imm19 = (tgt - pc) // 4
    assert -0x40000 <= imm19 < 0x40000
    return 0x58000000 | ((imm19 & 0x7FFFF) << 5) | rt


def cbz64(rt, pc, tgt):
    imm19 = (tgt - pc) // 4
    assert -0x40000 <= imm19 < 0x40000
    return 0xB4000000 | ((imm19 & 0x7FFFF) << 5) | rt


def assemble(gjs, moz):
    # +0  stp x0,x30
    # +4  ldr x0, slot_ptr
    # +8  ldr x0,[x0]
    # +12 cbz → restore
    # +16 ldr x0,[x0,#16]
    # +20 cbz → restore
    # +24 ldr x16, irq
    # +28 blr x16
    # +32 restore
    # +36 ret
    # +40 slot VA
    # +48 irq VA
    restore = CAVE + 32
    words = [
        0xa9bf7be0,
        ldr_lit(0, CAVE + 4, CAVE + 40),
        0xf9400000,
        cbz64(0, CAVE + 12, restore),
        0xf9400800,
        cbz64(0, CAVE + 20, restore),
        ldr_lit(16, CAVE + 24, CAVE + 48),
        0xd63f0200,
        0xa8c17be0,
        0xd65f03c0,
    ]
    return b"".join(struct.pack("<I", w) for w in words) + struct.pack(
        "<QQ", gjs + GJS_CUR, moz + MOZ_IRQ
    )


pid, mu, gjs, moz = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(gjs + GJS_CUR)
cur_slot = struct.unpack("<Q", mem.read(8))[0]
jsctx = 0
if cur_slot > 0x10000:
    mem.seek(cur_slot + 16)
    jsctx = struct.unpack("<Q", mem.read(8))[0]
mem.seek(mu + SITE)
site = struct.unpack("<I", mem.read(4))[0]
want_b = b_imm(SITE, CAVE)
print(
    f"pid={pid} mu={mu:#x} gjs={gjs:#x} moz={moz:#x} "
    f"gjs_cur={cur_slot:#x} jsctx={jsctx:#x} site={site:#x} want_b={want_b:#x}"
)
if cur_slot < 0x10000 or jsctx < 0x10000:
    raise SystemExit("gjs current/JSContext not live; abort")

blob = assemble(gjs, moz)
if cmd == "apply-live":
    mem.seek(mu + CAVE)
    mem.write(blob)
    mem.seek(mu + SITE)
    mem.write(struct.pack("<I", want_b))
    mem.seek(mu + SITE)
    print("wrote site", hex(struct.unpack("<I", mem.read(4))[0]), "cave", len(blob))
elif cmd == "restore-live":
    mem.seek(mu + SITE)
    mem.write(struct.pack("<I", STOCK_RET))
    mem.seek(mu + CAVE)
    mem.write(b"\x00" * len(blob))
    mem.seek(mu + SITE)
    print("restored site", hex(struct.unpack("<I", mem.read(4))[0]))
else:
    print("poked" if site == want_b else ("stock" if site == STOCK_RET else hex(site)))
mem.close()
PY
