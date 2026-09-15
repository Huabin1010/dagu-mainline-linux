#!/usr/bin/env bash
# Skip the infinite throttle_fence wait in Mesa 26.0.8 dri_flush.
# Live gallium (objdump-checked, gnome-shell maps):
#   0x1cf740  mov x3,#-1  → mov x3,#0
#   0x1cf74c  blr x4 (fence_finish) → nop
# fence_finish(0) still entered a userspace wait loop; NOP the call.
# st_context_flush 0x27215c/0x272168 NOP REJECTED (max 232ms B-main).
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
# (off, stock, poke)
sites = (
    (0x1CF740, 0x92800003, 0xD2800003),  # mov x3,#-1 → #0
    (0x1CF74C, 0xD63F0080, 0xD503201F),  # blr x4 → nop
)
so = pathlib.Path("/usr/lib/aarch64-linux-gnu/libgallium-26.0.8-1ubuntu0.3.so")
bak = pathlib.Path("/var/backups/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so.stock")


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
            if "libgallium-26.0.8" in line and "r-xp" in line:
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
    fv = file_ops()
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
    elif st == "mixed" and fv[0] not in (0x92800003, 0xD2800003):
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
