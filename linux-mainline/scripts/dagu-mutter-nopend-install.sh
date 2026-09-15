#!/usr/bin/env bash
# update_ready: when deadline timer is off, do not queue on
# pending_page_flip. schedule_process will not flush that queue
# (deadline off → g_warning_once only), so the next atomic waits
# until another update arrives (65-200 ms Type B hole).
# Live so 50.1, ELF (objdump-checked on map_files):
#   0x1bd7d4 cbnz w0, 0x1bd82c  (pending_page_flip → queue_update)
#        →   nop                (fall through to do_process_update)
# Does not restart gdm. Does not flash the kernel.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

case "$cmd" in
  status|apply|restore)
    "${SSH[@]}" python3 - "$cmd" <<'PY'
import struct, os, pathlib, shutil, sys
cmd = sys.argv[1]
OFF, STOCK, POKE = 0x1bd7d4, 0x350002c0, 0xd503201f
so = pathlib.Path("/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0")
bak = pathlib.Path("/var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2")


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
        maps = (p / "maps").read_text()
        base = None
        for line in maps.splitlines():
            if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
                base = int(line.split("-", 1)[0], 16)
                break
        if base is None:
            continue
        mem = open(p / "mem", "r+b", buffering=0)
        mem.seek(base + OFF)
        v = struct.unpack("<I", mem.read(4))[0]
        out.append((p.name, base, mem, v))
    return out


def classify(v):
    if v == POKE:
        return "poked"
    if v == STOCK:
        return "stock"
    return f"mixed {hex(v)}"


if cmd == "status":
    data = so.read_bytes()
    v = struct.unpack_from("<I", data, OFF)[0]
    print("file", classify(v), hex(v))
    for name, base, mem, val in live_shells():
        print("live", name, hex(base), classify(val), hex(val))
        mem.close()
elif cmd == "apply":
    data = bytearray(so.read_bytes())
    v = struct.unpack_from("<I", data, OFF)[0]
    st = classify(v)
    if st == "poked":
        print("file already poked")
    elif st == "stock":
        if not bak.exists():
            bak.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(so, bak)
        struct.pack_into("<I", data, OFF, POKE)
        tmp = so.with_suffix(so.suffix + ".new")
        tmp.write_bytes(data)
        os.chmod(tmp, 0o644)
        tmp.replace(so)
        print("file poked from stock")
    else:
        raise SystemExit(f"file {st}")
    for name, base, mem, val in live_shells():
        st = classify(val)
        if st == "poked":
            print("live", name, "already poked")
        elif st == "stock":
            mem.seek(base + OFF)
            mem.write(struct.pack("<I", POKE))
            print("live", name, "poked from stock")
        else:
            print("live", name, st)
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
    echo "usage: $0 {status|apply|restore}" >&2
    exit 2
    ;;
esac
