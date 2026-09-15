#!/usr/bin/env bash
# maybe_post_if_gl_finished: do not wait for Cogl sync_fd G_IO_IN.
# Live so 50.1, ELF (objdump-checked):
#   0x1c43f4  tbnz w0,#0,post  →  b post
# After nview, next_frame stays queued until render_source sees the
# fence. That fence is implicit-synced to scanout → 100ms Type B.
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
import os, pathlib, shutil, struct, sys
cmd = sys.argv[1]
OFF = 0x1C43F4
STOCK = 0x3707FE20  # tbnz w0,#0,0x1c43b8
POKE = 0x17FFFFF1   # b 0x1c43b8
so = pathlib.Path("/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0")
bak = pathlib.Path("/var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2")


def classify(v):
    if v == POKE:
        return "poked"
    if v == STOCK:
        return "stock"
    return f"mixed {hex(v)}"


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
            if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
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
elif cmd == "apply":
    data = bytearray(so.read_bytes())
    fv = struct.unpack_from("<I", data, OFF)[0]
    if fv == POKE:
        print("file already poked")
    elif fv != STOCK:
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
    for name, base, mem, val in live_shells():
        if val == POKE:
            print("live", name, "already poked")
        elif val != STOCK:
            print("live", name, "unexpected", hex(val))
        else:
            mem.seek(base + OFF)
            mem.write(struct.pack("<I", POKE))
            print("live", name, "poked")
        mem.close()
elif cmd == "restore":
    data = bytearray(so.read_bytes())
    fv = struct.unpack_from("<I", data, OFF)[0]
    if fv == POKE:
        struct.pack_into("<I", data, OFF, STOCK)
        tmp = so.with_suffix(so.suffix + ".new")
        tmp.write_bytes(data)
        os.chmod(tmp, 0o644)
        tmp.replace(so)
        print("file restored gl-ready site")
    else:
        print("file", classify(fv))
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
