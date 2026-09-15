#!/usr/bin/env bash
# after_update: emit wl_surface.frame immediately on IDLE too.
# Live so 50.1-0ubuntu2.2, ELF 0x169668 cbz w0,emit → b emit.
# Does not restart gdm. Pair with dagu-mutter-msm-infence-install.sh.
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
off = 0x169668
stock = 0x34000220  # cbz w0, emit_now
poke = 0x14000011   # b emit_now
so = pathlib.Path("/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0")
bak = pathlib.Path("/var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2")

def file_op():
    return struct.unpack_from("<I", so.read_bytes(), off)[0]

def live_ops():
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
        mem.seek(base + off)
        got = struct.unpack("<I", mem.read(4))[0]
        out.append((p.name, base, got, mem))
    return out

if cmd == "status":
    v = file_op()
    print("file", hex(v), "stock" if v == stock else ("poked" if v == poke else "unknown"))
    for name, base, got, mem in live_ops():
        print("live", name, hex(got), "stock" if got == stock else ("poked" if got == poke else "unknown"))
        mem.close()
    raise SystemExit(0)

if cmd == "apply":
    data = bytearray(so.read_bytes())
    cur = struct.unpack_from("<I", data, off)[0]
    if cur == poke:
        print("file already poked")
    elif cur != stock:
        raise SystemExit(f"unexpected opcode {cur:#x} at {off:#x}")
    else:
        if not bak.exists():
            bak.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(so, bak)
        struct.pack_into("<I", data, off, poke)
        tmp = so.with_suffix(so.suffix + ".new")
        tmp.write_bytes(data)
        os.chmod(tmp, 0o644)
        tmp.replace(so)
        print("file poked", hex(poke))
    for name, base, got, mem in live_ops():
        if got == stock:
            mem.seek(base + off)
            mem.write(struct.pack("<I", poke))
            print("live", name, "poked")
        elif got == poke:
            print("live", name, "already poked")
        else:
            print("live", name, "unexpected", hex(got))
        mem.close()
    raise SystemExit(0)

if cmd == "restore":
    data = bytearray(so.read_bytes())
    cur = struct.unpack_from("<I", data, off)[0]
    if cur == poke:
        struct.pack_into("<I", data, off, stock)
        tmp = so.with_suffix(so.suffix + ".new")
        tmp.write_bytes(data)
        os.chmod(tmp, 0o644)
        tmp.replace(so)
        print("file opcode restored")
    else:
        print("file opcode", hex(cur), "leave")
    for name, base, got, mem in live_ops():
        mem.seek(base + off)
        mem.write(struct.pack("<I", stock))
        print("live", name, "restored")
        mem.close()
PY
    ;;
  *)
    echo "usage: $0 {status|apply|restore}" >&2
    exit 2
    ;;
esac
