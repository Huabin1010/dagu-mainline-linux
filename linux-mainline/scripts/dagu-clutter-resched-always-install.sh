#!/usr/bin/env bash
# maybe_reschedule_update: always take the pending_reschedule path
# (schedule_update, not now). Live clutter 50.1 objdump-checked:
#   0x67bf8 cbnz w20,#396  →  b 0x67c04
# REJECTED 2026-09-14: 8s 107.3Hz / gt50=2 / max 115 (baseline 111.1 / 3 / 250).
# fcdisp doubled (empty paints); B-post-late gone but kickoff Hz dropped.
# Keep restore. Do not apply.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

case "$cmd" in
  status|apply|apply-live|restore)
    "${SSH[@]}" python3 - "$cmd" <<'PY'
import os, pathlib, shutil, struct, sys
cmd = sys.argv[1]
OFF, STOCK, POKE = 0x67bf8, 0x35000074, 0x14000003
so = pathlib.Path("/usr/lib/aarch64-linux-gnu/mutter-18/libmutter-clutter-18.so.0.0.0")
bak = pathlib.Path("/var/backups/dagu-mutter/libmutter-clutter-18.so.0.0.0.stock-50.1")


def classify(v):
    if v == POKE:
        return "poked"
    if v == STOCK:
        return "stock"
    return f"mixed:{hex(v)}"


def live_shells():
    out = []
    for p in pathlib.Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            c = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if not c.startswith(b"/usr/bin/gnome-shell"):
            continue
        base = None
        for line in (p / "maps").read_text().splitlines():
            if "libmutter-clutter-18.so" in line and "r-xp" in line:
                base = int(line.split("-", 1)[0], 16)
                break
        if base is None:
            continue
        mem = open(p / "mem", "r+b", buffering=0)
        mem.seek(base + OFF)
        val = struct.unpack("<I", mem.read(4))[0]
        out.append((p.name, base, mem, val))
    return out


if cmd == "status":
    fv = struct.unpack_from("<I", so.read_bytes(), OFF)[0]
    print("file", classify(fv), hex(fv))
    for name, base, mem, val in live_shells():
        print("live", name, hex(base), classify(val), hex(val))
        mem.close()
elif cmd in ("apply", "apply-live"):
    if cmd == "apply":
        data = bytearray(so.read_bytes())
        fv = struct.unpack_from("<I", data, OFF)[0]
        st = classify(fv)
        if st == "poked":
            print("file already poked")
        elif st != "stock":
            raise SystemExit(f"file unexpected {hex(fv)}")
        else:
            if not bak.exists():
                bak.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(so, bak)
            struct.pack_into("<I", data, OFF, POKE)
            tmp = so.with_suffix(so.suffix + ".new")
            tmp.write_bytes(data)
            os.chmod(tmp, 0o644)
            tmp.replace(so)
            print("file poked")
    else:
        print("file unchanged (apply-live)")
    for name, base, mem, val in live_shells():
        st = classify(val)
        if st == "poked":
            print("live", name, "already poked")
        elif st != "stock":
            print("live", name, "mixed", hex(val))
        else:
            mem.seek(base + OFF)
            mem.write(struct.pack("<I", POKE))
            print("live", name, "poked")
        mem.close()
elif cmd == "restore":
    data = bytearray(so.read_bytes())
    struct.pack_into("<I", data, OFF, STOCK)
    tmp = so.with_suffix(so.suffix + ".new")
    tmp.write_bytes(data)
    os.chmod(tmp, 0o644)
    tmp.replace(so)
    print("file restored")
    for name, base, mem, val in live_shells():
        mem.seek(base + OFF)
        mem.write(struct.pack("<I", STOCK))
        print("live", name, "restored")
        mem.close()
PY
    ;;
  *)
    echo "usage: $0 {status|apply-live|apply|restore}" >&2
    exit 2
    ;;
esac
