#!/usr/bin/env bash
# REJECTED: drop DRM_MODE_ATOMIC_NONBLOCK.
# Two quiet windows hit gt50=0 / 117-118 Hz, then relaunch 109.5 Hz
# gt50=6 max 241 (nview on time, maybe_post +90-240). Restore.
# Live so 50.1, objdump-checked: 0x1b4820 mov w22,#0x200
# Keep restore. Do not apply. Does not flash the kernel.
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
sites = (
    (0x1B4820, 0x52804016, 0x52800016),  # mov w22,#0x200 → #0
)
so = pathlib.Path("/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0")
bak = pathlib.Path("/var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2")


def classify(vals):
    if all(v == poke for (_, _, poke), v in zip(sites, vals)):
        return "poked"
    if all(v == stock for (_, stock, _), v in zip(sites, vals)):
        return "stock"
    return "mixed"


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
        vals = []
        for off, _, _ in sites:
            mem.seek(base + off)
            vals.append(struct.unpack("<I", mem.read(4))[0])
        out.append((p.name, base, mem, vals))
    return out


def poke_bytes(data, want_stock):
    for off, stock, poke in sites:
        struct.pack_into("<I", data, off, stock if want_stock else poke)


if cmd == "status":
    data = so.read_bytes()
    fv = [struct.unpack_from("<I", data, off)[0] for off, _, _ in sites]
    print("file", classify(fv), [hex(v) for v in fv])
    for name, base, mem, vals in live_shells():
        print("live", name, hex(base), classify(vals), [hex(v) for v in vals])
        mem.close()
elif cmd == "apply":
    data = bytearray(so.read_bytes())
    fv = [struct.unpack_from("<I", data, off)[0] for off, _, _ in sites]
    st = classify(fv)
    if st == "poked":
        print("file already poked")
    elif st == "mixed":
        raise SystemExit(f"file unexpected {[hex(v) for v in fv]}")
    else:
        if not bak.exists():
            bak.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(so, bak)
        poke_bytes(data, want_stock=False)
        tmp = so.with_suffix(so.suffix + ".new")
        tmp.write_bytes(data)
        os.chmod(tmp, 0o644)
        tmp.replace(so)
        print("file poked")
    for name, base, mem, vals in live_shells():
        st = classify(vals)
        if st == "poked":
            print("live", name, "already poked")
        elif st == "mixed":
            raise SystemExit(f"live unexpected {[hex(v) for v in vals]}")
        else:
            for off, _, poke in sites:
                mem.seek(base + off)
                mem.write(struct.pack("<I", poke))
            print("live", name, "poked")
        mem.close()
elif cmd == "restore":
    data = bytearray(so.read_bytes())
    poke_bytes(data, want_stock=True)
    tmp = so.with_suffix(so.suffix + ".new")
    tmp.write_bytes(data)
    os.chmod(tmp, 0o644)
    tmp.replace(so)
    print("file restored")
    for name, base, mem, vals in live_shells():
        for off, stock, _ in sites:
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
