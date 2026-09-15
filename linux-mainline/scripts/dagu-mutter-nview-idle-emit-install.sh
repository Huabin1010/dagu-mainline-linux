#!/usr/bin/env bash
# notify_view_crtc_presented tail: after promote, emit_frame_callbacks
# then maybe_post. present→IDLE path never runs after_update, so the
# empty-frame GSource never arms; GTK waits on wl_surface.frame.
# Live ubuntu only. Cave 0x1d1bd8 (not 0x1d2b80 apply-wakeup).
# Does not write the disk so. usage: status|apply|restore
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
CAVE = 0x1D1BD8
SITE = 0x1C44F8
SITE_STOCK = 0x17FFFFA2  # b 0x1c4380 maybe_post
MAYBE_POST = 0x1C4380
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


def b(pc, tgt):
    return 0x14000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def bl(pc, tgt):
    return 0x94000000 | (((tgt - pc) // 4) & 0x3FFFFFF)


def mov_imm64(rd, val):
    words = []
    for shift in (0, 16, 32, 48):
        part = (val >> shift) & 0xFFFF
        if shift == 0:
            words.append(0xD2800000 | (part << 5) | rd)
        elif part:
            words.append(0xF2800000 | ((shift // 16) << 21) | (part << 5) | rd)
    return words


def assemble(comp):
    words = []

    def here():
        return CAVE + 4 * len(words)

    words.append(0xF81F0FFE)          # str x30,[sp,#-16]!
    words.append(0xF90007E0)          # str x0,[sp,#8]  onscreen
    words.append(0xF9404401)          # ldr x1,[x0,#136] view
    cbz_at = len(words)
    words.append(0xB4000001)          # cbz x1, restore (patched)
    words.extend(mov_imm64(0, comp))
    words.append(bl(here(), EMIT))
    restore = len(words)
    words[cbz_at] = 0xB4000001 | (((restore - cbz_at) & 0x7FFFF) << 5)
    words.append(0xF94007E0)          # ldr x0,[sp,#8]
    words.append(0xF84107FE)          # ldr x30,[sp],#16
    words.append(b(here(), MAYBE_POST))
    return words


def discover_comp(pid, mf):
    kick = (TR / "events/dpu/dpu_enc_kickoff/enable").read_text().strip()
    vbl = "0"
    vp = TR / "events/dpu/dpu_crtc_vblank_cb/enable"
    if vp.is_file():
        vbl = vp.read_text().strip()
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
    t_end = time.time() + 0.5
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
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text(kick + "\n")
    if vp.is_file():
        vp.write_text(vbl + "\n")
    (TR / "tracing_on").write_text("1\n")
    if not comp:
        raise SystemExit("no compositor from after_update")
    return comp


pid, base, mf = find_ubuntu()
mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
site = u32(mem, base + SITE)
cave0 = [u32(mem, base + CAVE + 4 * i) for i in range(16)]
print("pid", pid, "base", hex(base), "site", hex(site), "stock", hex(SITE_STOCK))
print("cave0", [hex(x) for x in cave0[:8]])

if cmd == "status":
    print("live", "poked" if site != SITE_STOCK else "stock")
elif cmd == "apply":
    if site != SITE_STOCK:
        raise SystemExit(f"1c44f8 not stock b maybe_post: {site:#x}")
    if any(cave0):
        raise SystemExit(f"cave not empty: {[hex(x) for x in cave0]}")
    mem.close()
    comp = discover_comp(pid, mf)
    print("compositor", hex(comp))
    mem = open(f"/proc/{pid}/mem", "r+b", buffering=0)
    want = assemble(comp)
    if len(want) > 16:
        raise SystemExit(f"cave too long {len(want)}")
    for i, w in enumerate(want):
        w32(mem, base + CAVE + 4 * i, w)
    w32(mem, base + SITE, b(SITE, CAVE))
    print("poked", "site", hex(b(SITE, CAVE)), "nwords", len(want), [hex(x) for x in want])
elif cmd == "restore":
    w32(mem, base + SITE, SITE_STOCK)
    for i in range(16):
        w32(mem, base + CAVE + 4 * i, 0)
    print("restored")
mem.close()
print("tracing_on", TR.joinpath("tracing_on").read_text().strip())
print("kickoff", (TR / "events/dpu/dpu_enc_kickoff/enable").read_text().strip())
print("shell", Path(f"/proc/{pid}/comm").read_text().strip() if Path(f"/proc/{pid}/comm").exists() else "gone")
PY
    ;;
  *)
    echo "usage: $0 {status|apply|restore}" >&2
    exit 2
    ;;
esac
