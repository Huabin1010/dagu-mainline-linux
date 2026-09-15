#!/usr/bin/env bash
# is_using_deadline_timer: if state==ENABLED, return TRUE even when
# KMS thread scheduling priority is NORMAL (rtkit never raised it).
# Live so 50.1, ELF (objdump-checked):
#   0x1bbd30 cbz w1, 0x1bbd3c   state==0 ENABLED → body
#   0x1bbd3c paciasp / get_priority  →  mov w0,#1; ret
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
sites = (
    (0x1bbd3c, 0xd503233f, 0x52800020),  # paciasp → mov w0,#1
    (0x1bbd40, 0xa9bf7bfd, 0xd65f03c0),  # stp     → ret
)
so = pathlib.Path("/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0")
bak = pathlib.Path("/var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2")


def classify(vals):
    if all(v == p for (_, _, p), v in zip(sites, vals)):
        return "poked"
    if all(v == s for (_, s, _), v in zip(sites, vals)):
        return "stock"
    return "mixed"


def file_vals(data=None):
    data = data if data is not None else so.read_bytes()
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
        maps = (p / "maps").read_text()
        base = None
        for line in maps.splitlines():
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


if cmd == "status":
    fv = file_vals()
    print("file", classify(fv), [hex(v) for v in fv])
    for name, base, mem, vals in live_shells():
        print("live", name, hex(base), classify(vals), [hex(v) for v in vals])
        mem.close()
elif cmd == "apply":
    data = bytearray(so.read_bytes())
    fv = file_vals(data)
    st = classify(fv)
    if st == "poked":
        print("file already poked")
    elif st != "stock":
        raise SystemExit(f"file mixed {[hex(v) for v in fv]}")
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
    for name, base, mem, vals in live_shells():
        st = classify(vals)
        if st == "poked":
            print("live", name, "already poked")
        elif st != "stock":
            print("live", name, "mixed", [hex(v) for v in vals])
        else:
            for off, _, poke in sites:
                mem.seek(base + off)
                mem.write(struct.pack("<I", poke))
            print("live", name, "poked")
        mem.close()
elif cmd == "restore":
    data = bytearray(so.read_bytes())
    for off, stock, _ in sites:
        struct.pack_into("<I", data, off, stock)
    tmp = so.with_suffix(so.suffix + ".new")
    tmp.write_bytes(data)
    os.chmod(tmp, 0o644)
    tmp.replace(so)
    print("file restored deadline sites")
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
