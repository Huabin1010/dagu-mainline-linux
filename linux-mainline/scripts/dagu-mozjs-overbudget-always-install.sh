#!/usr/bin/env bash
# Live-only: SliceBudget::checkOverBudget always returns true.
# Unlimited JS_GC (kind=2) otherwise never checks wall time; sweep can
# occupy the main thread 70–120ms while the KMS callback source is already
# ready. Forcing over-budget lets JS_GC return to GLib between work units.
# Not JS_GC site 4ms/1ms, not MaybeGC, not idle-defer, not iter-slice nested
# iteration, not KMS interrupt. Does not write the disk so.
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
SITE = 0x60C220
# stock first 4 insns after identifying the function
STOCK = bytes.fromhex("3f2303d5fe4fbea9f30300aa00804039")
# paciasp; mov w0,#1; autiasp; ret
POKE = struct.pack("<IIII", 0xD503233F, 0x52800020, 0xD50323BF, 0xD65F03C0)


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
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
mem.seek(moz + SITE)
cur = mem.read(16)
print(f"pid={pid} moz={moz:#x} site={cur.hex()}")
if cmd == "apply-live":
    if cur != STOCK:
        raise SystemExit(f"unexpected site {cur.hex()} want {STOCK.hex()}")
    mem.seek(moz + SITE)
    mem.write(POKE)
    mem.seek(moz + SITE)
    print("wrote", mem.read(16).hex())
elif cmd == "restore-live":
    mem.seek(moz + SITE)
    mem.write(STOCK)
    mem.seek(moz + SITE)
    print("restored", mem.read(16).hex())
else:
    print("poked" if cur == POKE else ("stock" if cur == STOCK else "mixed"))
mem.close()
print("tracing_on", pathlib.Path("/sys/kernel/debug/tracing/tracing_on").read_text().strip())
print("kickoff", pathlib.Path("/sys/kernel/debug/tracing/events/dpu/dpu_enc_kickoff/enable").read_text().strip())
PY
