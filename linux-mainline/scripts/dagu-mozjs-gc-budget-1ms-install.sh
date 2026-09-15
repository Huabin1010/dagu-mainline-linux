#!/usr/bin/env bash
# Live-only: JS_GC unlimited SliceBudget → 1ms TimeBudget.
# Not the rejected 4ms poke (dagu-mozjs-gc-budget-install.sh: more 50ms holes).
# Not MaybeGC / IncrementalGCSlice / skip-hammer / idle-defer / iter-slice /
# KMS interrupt. Does not write the disk so. Does not restart gnome-shell.
# Cave mozjs 0x410038. Site 0x44c730. ticks=ns; 1ms=1000000.
# usage: status|apply-live|restore-live
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

"${SSH[@]}" python3 - "$cmd" <<'PY'
import struct, pathlib, sys
cmd = sys.argv[1]
SITE = 0x44C730
STOCK = 0x92F00005  # mov x5, #0x7fffffffffffffff
CAVE = 0x410038
DEADLINE = 0x60C1A0  # TimeBudget::setDeadlineFromNow
GC_CONT = 0x44C750


def b_imm(pc, tgt):
    return 0x14000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def bl_imm(pc, tgt):
    return 0x94000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def assemble():
    words = []

    def here():
        return CAVE + 4 * len(words)

    def emit(w):
        words.append(w & 0xFFFFFFFF)

    emit(0xD2807D05)          # mov x5, #1000
    emit(0xA901FFE5)          # stp x5, xzr, [sp, #24]
    emit(0xD2884805)          # movz x5, #0x4240
    emit(0xF2A001E5)          # movk x5, #0xf, lsl #16  ; 1000000
    emit(0xF90017E5)          # str x5, [sp, #40]
    emit(0x3900E3FF)          # strb wzr, [sp, #56] mode=time
    emit(0x390103FF)          # strb wzr, [sp, #64] over-flag
    emit(0x9100A3E0)          # add x0, sp, #40
    emit(bl_imm(here(), DEADLINE))
    emit(0xF9406E62)          # ldr x2, [x19, #216]
    emit(0x9117C040)          # add x0, x2, #0x5f0
    emit(0x910063E2)          # add x2, sp, #0x18
    emit(0x52800021)          # mov w1, #1
    emit(b_imm(here(), GC_CONT))
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
            if "libmozjs-140" in line and "r-xp" in line:
                return int(p.name), int(line.split("-", 1)[0], 16)
    raise SystemExit("no ubuntu mozjs")


pid, moz = find_ubuntu()
blob = assemble()
want_b = b_imm(SITE, CAVE)
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(moz + SITE)
site = struct.unpack("<I", mem.read(4))[0]
mem.seek(moz + CAVE)
pad = mem.read(16)
print(
    f"pid={pid} moz={moz:#x} site={site:#x} want_b={want_b:#x} "
    f"cave_pad={pad.hex()} cave_bytes={len(blob)}"
)
if pad != b"\x00" * 16 and cmd == "apply-live":
    if site != want_b:
        raise SystemExit("cave not zeros; abort")

if cmd == "apply-live":
    if site not in (STOCK, want_b):
        raise SystemExit(f"unexpected site {site:#x}")
    mem.seek(moz + CAVE)
    mem.write(blob)
    mem.seek(moz + SITE)
    mem.write(struct.pack("<I", want_b))
    mem.seek(moz + SITE)
    print("wrote site", hex(struct.unpack("<I", mem.read(4))[0]))
elif cmd == "restore-live":
    mem.seek(moz + SITE)
    mem.write(struct.pack("<I", STOCK))
    mem.seek(moz + CAVE)
    mem.write(b"\x00" * len(blob))
    mem.seek(moz + SITE)
    print("restored site", hex(struct.unpack("<I", mem.read(4))[0]))
else:
    print("poked" if site == want_b else ("stock" if site == STOCK else hex(site)))
mem.close()
print("tracing_on", pathlib.Path("/sys/kernel/debug/tracing/tracing_on").read_text().strip())
print("kickoff", pathlib.Path("/sys/kernel/debug/tracing/events/dpu/dpu_enc_kickoff/enable").read_text().strip())
PY
