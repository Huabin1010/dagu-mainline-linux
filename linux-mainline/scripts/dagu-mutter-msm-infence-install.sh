#!/usr/bin/env bash
# do_handle_update: still set DISABLE_IMPLICIT_SYNC when sync_fd>=0,
# but never g_poll / register_fd-wait the Cogl fence.
# Live so 50.1, ELF (objdump-checked):
#   0x1bd9ac tbnz w20,#31,update_ready   — keep STOCK
#   0x1bd9d8 mov w1,#1 (g_poll setup)    → b 0x1bda00 update_ready
# Old knife jumped 0x1bd9ac → update_ready and skipped DISABLE; that
# left implicit GEM on and is B-kick. This script migrates that away.
# Does not flash the kernel. Does not restart gdm unless --restart-shell.
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
# (off, stock, poke)  poke==stock means "must be stock"
# 0x1bd9ac must stay stock tbnz; old knife used 0x14000015
TBNZ = (0x1bd9ac, 0x37f802b4, 0x37f802b4)
OLD_TBNZ_POKE = 0x14000015
SKIP_POLL = (0x1bd9d8, 0x52800021, 0x1400000a)
so = pathlib.Path("/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0")
bak = pathlib.Path("/var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2")


def read4(data, off):
    return struct.unpack_from("<I", data, off)[0]


def classify_pair(tbnz, skip):
    if tbnz == OLD_TBNZ_POKE:
        return "old-knife"
    if tbnz == TBNZ[1] and skip == SKIP_POLL[2]:
        return "poked"
    if tbnz == TBNZ[1] and skip == SKIP_POLL[1]:
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
        maps = (p / "maps").read_text()
        base = None
        for line in maps.splitlines():
            if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
                base = int(line.split("-", 1)[0], 16)
                break
        if base is None:
            continue
        mem = open(p / "mem", "r+b", buffering=0)
        mem.seek(base + TBNZ[0])
        tbnz = struct.unpack("<I", mem.read(4))[0]
        mem.seek(base + SKIP_POLL[0])
        skip = struct.unpack("<I", mem.read(4))[0]
        out.append((p.name, base, mem, tbnz, skip))
    return out


def write_pair(buf, tbnz, skip):
    struct.pack_into("<I", buf, TBNZ[0], tbnz)
    struct.pack_into("<I", buf, SKIP_POLL[0], skip)


if cmd == "status":
    data = so.read_bytes()
    tbnz, skip = read4(data, TBNZ[0]), read4(data, SKIP_POLL[0])
    print("file", classify_pair(tbnz, skip), hex(tbnz), hex(skip))
    for name, base, mem, t, s in live_shells():
        print("live", name, hex(base), classify_pair(t, s), hex(t), hex(s))
        mem.close()
elif cmd == "apply":
    data = bytearray(so.read_bytes())
    tbnz, skip = read4(data, TBNZ[0]), read4(data, SKIP_POLL[0])
    st = classify_pair(tbnz, skip)
    if st == "poked":
        print("file already poked")
    elif st in ("stock", "old-knife"):
        if not bak.exists():
            bak.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(so, bak)
        write_pair(data, TBNZ[1], SKIP_POLL[2])
        tmp = so.with_suffix(so.suffix + ".new")
        tmp.write_bytes(data)
        os.chmod(tmp, 0o644)
        tmp.replace(so)
        print("file poked from", st)
    else:
        raise SystemExit(f"file mixed {hex(tbnz)} {hex(skip)}")
    for name, base, mem, t, s in live_shells():
        st = classify_pair(t, s)
        if st == "poked":
            print("live", name, "already poked")
        elif st in ("stock", "old-knife"):
            mem.seek(base + TBNZ[0])
            mem.write(struct.pack("<I", TBNZ[1]))
            mem.seek(base + SKIP_POLL[0])
            mem.write(struct.pack("<I", SKIP_POLL[2]))
            print("live", name, "poked from", st)
        else:
            print("live", name, "mixed", hex(t), hex(s))
        mem.close()
elif cmd == "restore":
    data = bytearray(so.read_bytes())
    write_pair(data, TBNZ[1], SKIP_POLL[1])
    tmp = so.with_suffix(so.suffix + ".new")
    tmp.write_bytes(data)
    os.chmod(tmp, 0o644)
    tmp.replace(so)
    print("file restored to stock do_handle_update")
    for name, base, mem, t, s in live_shells():
        mem.seek(base + TBNZ[0])
        mem.write(struct.pack("<I", TBNZ[1]))
        mem.seek(base + SKIP_POLL[0])
        mem.write(struct.pack("<I", SKIP_POLL[1]))
        print("live", name, "restored")
        mem.close()
PY
    ;;
  *)
    echo "usage: $0 {status|apply|restore}" >&2
    exit 2
    ;;
esac
