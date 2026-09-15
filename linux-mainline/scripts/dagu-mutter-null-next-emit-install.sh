#!/usr/bin/env bash
# ifgl next==NULL (0x1c4404): emit_frame_callbacks(compositor, view).
# Live ubuntu only. Cave 0x1d2b80. Does not write the disk so.
# Discover compositor from one after_update (x20). usage: status|apply|restore
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$ROOT/linux-mainline/out/id_dagu"
HOST="${DAGU_HOST:-192.168.7.2}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST")

cmd="${1:-status}"

case "$cmd" in
  status|apply|restore)
    "${SSH[@]}" python3 - "$cmd" <<'PY'
import os, struct, sys, time
from pathlib import Path

cmd = sys.argv[1]
CAVE = 0x1D2B80
BR = 0x1C4404
BR_STOCK = 0xD65F03C0
EMIT = 0x167340
VIEW_OFF = 136
AU = 0x1696BC
TR = Path("/sys/kernel/debug/tracing")


def find_ubuntu():
    for p in Path("/proc").iterdir():
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
        mf = None
        for line in maps.splitlines():
            if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
                base = int(line.split("-", 1)[0], 16)
                rng = line.split()[0]
                mf = f"/proc/{p.name}/map_files/{rng}"
                break
        if base is None:
            continue
        return int(p.name), base, mf
    raise SystemExit("no ubuntu gnome-shell")


def u32(mem, addr):
    mem.seek(addr)
    return struct.unpack("<I", mem.read(4))[0]


def w32(mem, addr, val):
    mem.seek(addr)
    mem.write(struct.pack("<I", val))


def mov_imm64(rd, val):
    words = []
    for shift in (0, 16, 32, 48):
        part = (val >> shift) & 0xFFFF
        if shift == 0:
            words.append(0xD2800000 | (part << 5) | rd)  # movz
        elif part:
            words.append(0xF2800000 | (shift // 16 << 21) | (part << 5) | rd)  # movk
    return words


def assemble(comp):
    words = []

    def here():
        return CAVE + 4 * len(words)

    words.append(0xF81F0FFE)  # str x30,[sp,#-16]!
    words.append(0xF9404401)  # ldr x1,[x0,#136]
    cbz_at = len(words)
    words.append(0xB4000001)  # cbz x1, patched
    words.extend(mov_imm64(0, comp))
    bl_pc = here()
    imm26 = ((EMIT - bl_pc) // 4) & 0x3FFFFFF
    words.append(0x94000000 | imm26)
    restore = len(words)
    words[cbz_at] = 0xB4000001 | (((restore - cbz_at) & 0x7FFFF) << 5)
    words.append(0xF84107FE)  # ldr x30,[sp],#16
    words.append(0xD65F03C0)  # ret
    return words


def br_word():
    return 0x14000000 | (((CAVE - BR) // 4) & 0x3FFFFFF)


def discover_comp(pid, mf, base):
    (TR / "tracing_on").write_text("0\n")
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        time.sleep(0.05)
        (TR / "uprobe_events").write_text("")
    (TR / "trace").write_text("")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_aucomp {mf}:{AU:#x} comp=%x20\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")
    t_end = time.time() + 0.4
    comp = None
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    os.set_blocking(pipe.fileno(), False)
    buf = ""
    try:
        while time.time() < t_end and comp is None:
            try:
                chunk = pipe.read(65536)
            except BlockingIOError:
                chunk = ""
            if not chunk:
                time.sleep(0.002)
                continue
            buf += chunk
            while "\n" in buf and comp is None:
                line, buf = buf.split("\n", 1)
                i = line.find("comp=")
                if i < 0:
                    continue
                v = line[i + 5 :].split()[0]
                try:
                    comp = int(v, 16)
                except ValueError:
                    pass
    finally:
        pipe.close()
    (TR / "tracing_on").write_text("0\n")
    (TR / "events/uprobes/enable").write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    (TR / "tracing_on").write_text("1\n")
    if not comp:
        raise SystemExit("no compositor from after_update")
    return comp


pid, base, mf = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
br = u32(mem, base + BR)
cave0 = [u32(mem, base + CAVE + 4 * i) for i in range(12)]
print("pid", pid, "base", hex(base), "br", hex(br), "cave0", hex(cave0[0]))

if cmd == "status":
    print("live", "poked" if br != BR_STOCK else "stock")
elif cmd == "apply":
    if br != BR_STOCK:
        raise SystemExit(f"1c4404 not stock ret: {br:#x}")
    if any(cave0):
        raise SystemExit(f"cave not empty: {[hex(x) for x in cave0]}")
    mem.close()
    comp = discover_comp(pid, mf, base)
    print("compositor", hex(comp))
    mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
    want = assemble(comp)
    if len(want) > 12:
        raise SystemExit(f"cave too long {len(want)}")
    for i, w in enumerate(want):
        w32(mem, base + CAVE + 4 * i, w)
    w32(mem, base + BR, br_word())
    print("poked", "br", hex(br_word()), "nwords", len(want), [hex(x) for x in want])
elif cmd == "restore":
    w32(mem, base + BR, BR_STOCK)
    for i in range(12):
        w32(mem, base + CAVE + 4 * i, 0)
    print("restored")
mem.close()
print("tracing_on", Path("/sys/kernel/debug/tracing/tracing_on").read_text().strip())
PY
    ;;
  *)
    echo "usage: $0 {status|apply|restore}" >&2
    exit 2
    ;;
esac
