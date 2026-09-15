#!/usr/bin/env bash
# maybe_post: do not copy Cogl sync_fd onto the KMS update (IN_FENCE).
# Live so 50.1, ELF:
#   0x1c2350 str w1,[x28,#96]  steal frame fd
#   0x1c2354 tbz w20,#31,set_sync_fd
# → both NOP. Frame release still g_clear_fd.
# Does not restart gdm.
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
    (0x1c2350, 0xb9006381, 0xd503201f),  # steal store -1
    (0x1c2354, 0x36f80df4, 0xd503201f),  # tbz to set_sync_fd
)
so = pathlib.Path("/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0")
bak = pathlib.Path("/var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2")

def classify(vals):
    if all(v == p for (_, _, p), v in zip(sites, vals)):
        return "poked"
    if all(v == s for (_, s, _), v in zip(sites, vals)):
        return "stock"
    return "mixed"

def file_ops():
    data = so.read_bytes()
    return [struct.unpack_from("<I", data, off)[0] for off, _, _ in sites]

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
        out.append((p.name, base, vals, mem))
    return out

if cmd == "status":
    fv = file_ops()
    print("file", [hex(v) for v in fv], classify(fv))
    for name, base, vals, mem in live_shells():
        print("live", name, [hex(v) for v in vals], classify(vals))
        mem.close()
    raise SystemExit(0)

if cmd == "apply":
    data = bytearray(so.read_bytes())
    fv = [struct.unpack_from("<I", data, off)[0] for off, _, _ in sites]
    st = classify(fv)
    if st == "poked":
        print("file already poked")
    elif st != "stock":
        raise SystemExit(f"unexpected file opcodes {[hex(v) for v in fv]}")
    else:
        if not bak.exists():
            bak.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(so, bak)
        for off, _, poke in sites:
            struct.pack_into("<I", data, off, poke)
        tmp = so.with_suffix(so.suffix + ".new")
        tmp.write_bytes(data)
        os.chmod(tmp, 0o644)
        tmp.replace(so)
        print("file poked")
    for name, base, vals, mem in live_shells():
        st = classify(vals)
        if st == "stock":
            for off, _, poke in sites:
                mem.seek(base + off)
                mem.write(struct.pack("<I", poke))
            print("live", name, "poked")
        elif st == "poked":
            print("live", name, "already poked")
        else:
            print("live", name, "unexpected", [hex(v) for v in vals])
        mem.close()
    raise SystemExit(0)

if cmd == "restore":
    data = bytearray(so.read_bytes())
    fv = [struct.unpack_from("<I", data, off)[0] for off, _, _ in sites]
    if classify(fv) == "poked":
        for off, stock, _ in sites:
            struct.pack_into("<I", data, off, stock)
        tmp = so.with_suffix(so.suffix + ".new")
        tmp.write_bytes(data)
        os.chmod(tmp, 0o644)
        tmp.replace(so)
        print("file opcodes restored")
    else:
        print("file", [hex(v) for v in fv], "leave")
    for name, base, vals, mem in live_shells():
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
