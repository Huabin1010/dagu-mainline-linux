#!/usr/bin/env bash
# After set_ready_time(0) in meta_thread_queue_callback, also
# g_main_context_wakeup(callback_source->main_context).
# Live so 50.1, ELF (objdump-checked):
#   0x1d6e94 cbz x0, fail-warning  →  cbz x0, unlock-ret
#   0x1d6ee4 bl set_ready_time     →  bl cave @ 0x1d6f10
#   0x1d6f10 cave: set_ready_time; wakeup(+128); ret
# wakeup(NULL→default) 已否（qcb +4.7 仍 nview +89）。不要再叠。
# Live poke ubuntu only. Does not restart gdm. Does not flash the kernel.
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
# (off, stock, poke)
sites = (
    (0x1d6e94, 0xb40003e0, 0xb4000300),  # cbz fail → unlock-ret
    (0x1d6ee4, 0x97fa41bf, 0x9400000b),  # bl set_ready_time → bl cave
    (0x1d6f10, 0xf00002a1, 0xf81f0ffe),  # adrp x1 → str x30,[sp,#-16]!
    (0x1d6f14, 0x910dc021, 0x97fa41b3),  # add  → bl set_ready_time
    (0x1d6f18, 0xd0000202, 0xf9404260),  # adrp → ldr x0,[x19,#128]
    (0x1d6f1c, 0xd0000060, 0xb4000040),  # adrp → cbz x0, +8
    (0x1d6f20, 0x911ac042, 0x97fa454c),  # add  → bl wakeup
    (0x1d6f24, 0x91048021, 0xf84107fe),  # add  → ldr x30,[sp],#16
    (0x1d6f28, 0x91016000, 0xd65f03c0),  # add  → ret
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
        if not c.startswith(b"/usr/bin/gnome-shell") or b"--mode=ubuntu" not in c:
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


def poke_bytes(data: bytearray, want_stock: bool):
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
    elif st != "stock" and fv[1] not in (0x97fa41bf, 0x9400000b):
        raise SystemExit(f"file mixed {[hex(v) for v in fv]}")
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
        elif st != "stock" and vals[1] not in (0x97fa41bf, 0x9400000b):
            print("live", name, "mixed", [hex(v) for v in vals])
        else:
            for off, _, poke in sites:
                mem.seek(base + off)
                mem.write(struct.pack("<I", poke))
            print("live", name, "poked")
        mem.close()
elif cmd == "restore":
    data = bytearray(so.read_bytes())
    fv = [struct.unpack_from("<I", data, off)[0] for off, _, _ in sites]
    if classify(fv) == "poked" or classify(fv) == "mixed":
        poke_bytes(data, want_stock=True)
        # keep first-knife byte if present
        # do not restore whole file from bak (that would undo 0x1bd9ac)
        tmp = so.with_suffix(so.suffix + ".new")
        tmp.write_bytes(data)
        os.chmod(tmp, 0o644)
        tmp.replace(so)
        print("file restored wakeup sites")
    else:
        print("file already stock")
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
