#!/usr/bin/env python3
"""Sample default GMainContext at qcb(x1==default), not onscreen x1==0.

GLib 2.88 live offsets (objdump libglib-2.0.so.0.8800.0):
  ctx+24 owner (GThread*), +32 owner_count, +40 waiters, +48 ref,
  +112 in_check_or_prepare, +152 wakeup, +192 prepare scratch
  source+32 context, +40 prio, +44 flags, +88 priv, priv+16 ready_time
  source+136 callbacks, +144 needs_flush

From host: python3 linux-mainline/scripts/dagu-qcb-ctx-sample.py --host
"""
from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")

DEFAULT = 0x559E7E61F0
SRC_DEFAULT = 0x559EC1ACE0
GLIB_SLOT = 0x180A90


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def find_pids() -> tuple[int, int]:
    shell = lab = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell") and b"--mode=ubuntu" in cmd:
            shell = int(p.name)
        elif cmd.startswith(b"python3\x00/usr/local/sbin/dagu-native-lab.py"):
            lab = int(p.name)
    if shell is None or lab is None:
        raise SystemExit(json.dumps({"err": "need ubuntu+lab", "shell": shell, "lab": lab}))
    return shell, lab


def map_base(pid: int, needle: str) -> int:
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" in line:
            continue
        return int(line.split("-", 1)[0], 16)
    raise SystemExit(f"no r-xp {needle}")


def map_rx(pid: int, needle: str) -> str:
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" in line:
            continue
        rng = line.split()[0]
        mf = f"/proc/{pid}/map_files/{rng}"
        if Path(mf).exists():
            return mf
    raise SystemExit(f"no r-xp {needle} pid={pid}")


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def u64(mem, a: int) -> int:
    mem.seek(a)
    return struct.unpack("<Q", mem.read(8))[0]


def i32(mem, a: int) -> int:
    mem.seek(a)
    return struct.unpack("<i", mem.read(4))[0]


def u32(mem, a: int) -> int:
    mem.seek(a)
    return struct.unpack("<I", mem.read(4))[0]


def evcount(pid: int, fd: int) -> int | None:
    try:
        raw = Path(f"/proc/{pid}/fdinfo/{fd}").read_text()
    except OSError:
        return None
    for line in raw.splitlines():
        if line.startswith("eventfd-count:"):
            return int(line.split()[1], 16)
    return None


def read_sys(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/syscall").read_text().strip().split()[0]
    except OSError:
        return "gone"


def sample_ctx(pid: int, ctx: int, src: int) -> dict:
    rec: dict = {"sys": read_sys(pid), "efd3": evcount(pid, 3)}
    try:
        rec["wchan"] = Path(f"/proc/{pid}/wchan").read_text().strip()[:40]
    except OSError:
        rec["wchan"] = ""
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
    except OSError:
        return rec
    try:
        rec["owner"] = hex(u64(mem, ctx + 24))
        rec["ocnt"] = u32(mem, ctx + 32)
        rec["waiters"] = hex(u64(mem, ctx + 40))
        rec["ref"] = i32(mem, ctx + 48)
        rec["in_check"] = i32(mem, ctx + 112)
        rec["scratch192"] = i32(mem, ctx + 192)
        rec["src_ctx"] = hex(u64(mem, src + 32))
        rec["prio"] = i32(mem, src + 40)
        rec["flags"] = hex(u32(mem, src + 44))
        rec["cb"] = hex(u64(mem, src + 136))
        rec["flush"] = u32(mem, src + 144)
        priv = u64(mem, src + 88)
        rec["priv"] = hex(priv)
        if priv:
            rec["ready"] = u64(mem, priv + 16)
            if rec["ready"] == (1 << 64) - 1:
                rec["ready"] = -1
        rec["owner_eq_idle"] = None
    except OSError:
        rec["mem"] = "fail"
    finally:
        mem.close()
    others = []
    task = Path(f"/proc/{pid}/task")
    try:
        for t in task.iterdir():
            tid = t.name
            try:
                sysn = (t / "syscall").read_text().strip().split()[0]
            except OSError:
                continue
            if sysn in ("73", "running", "98") or tid == str(pid):
                comm = ""
                try:
                    comm = (t / "comm").read_text().strip()
                except OSError:
                    pass
                others.append(f"{tid}:{comm}:{sysn}")
    except OSError:
        pass
    rec["tasks"] = others[:12]
    return rec


def install(shell: int) -> str:
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
    (TR / "buffer_size_kb").write_text("16384\n")
    mf = map_rx(shell, "libmutter-18.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_qcb {mf}:0x1d6e40 x1=%x1\n".encode())
        os.write(fd, f"p:dagu_nview {mf}:0x1c4440\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")
    return mf


def clear() -> None:
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    p = TR / "events/dpu/dpu_crtc_complete_flip/enable"
    if p.is_file():
        p.write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds: float = 8.0) -> int:
    shell, lab = find_pids()
    glib = map_base(shell, "libglib-2.0.so.0.8800.0")
    mem = open(f"/proc/{shell}/mem", "rb")
    ctx = u64(mem, glib + GLIB_SLOT)
    mem.close()
    src = SRC_DEFAULT
    idle = sample_ctx(shell, ctx, src)
    idle_owner = idle.get("owner")
    install(shell)
    snaps: list[dict] = []
    kick: list[float] = []
    flip: list[float] = []
    qcbd: list[float] = []
    nview: list[float] = []
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    want = hex(ctx)
    try:
        os.set_blocking(pipe.fileno(), False)
        buf = ""
        while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
            try:
                chunk = pipe.read(65536)
            except BlockingIOError:
                chunk = ""
            if not chunk:
                time.sleep(0.0002)
                continue
            buf += chunk
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                ts = parse_ts(line)
                if ts is None:
                    continue
                if "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                elif "dpu_crtc_complete_flip:" in line:
                    flip.append(ts)
                elif "dagu_nview:" in line:
                    nview.append(ts)
                if "dagu_qcb:" not in line or f"x1={want}" not in line:
                    continue
                qcbd.append(ts)
                rec = sample_ctx(shell, ctx, src)
                rec["t"] = ts
                rec["owner_eq_idle"] = rec.get("owner") == idle_owner
                snaps.append(rec)
    finally:
        pipe.close()
    (TR / "tracing_on").write_text("0\n")
    clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        q = [round((x - a) * 1000.0, 2) for x in qcbd if a - 0.006 <= x <= b + 0.002]
        n = [round((x - a) * 1000.0, 2) for x in nview if a - 0.006 <= x <= b + 0.002]
        f = [round((x - a) * 1000.0, 2) for x in flip if a - 0.008 <= x <= b + 0.002]
        early_q = [x for x in q if -2 <= x <= 15]
        late_n = [x for x in n if x >= 40]
        early_n = [x for x in n if -2 <= x <= 15]
        nows = []
        for s in snaps:
            if s.get("t") is None:
                continue
            dt = (s["t"] - a) * 1000.0
            if -2 <= dt <= 20 or (early_q and abs(dt - early_q[0]) < 2):
                slim = {k: s[k] for k in (
                    "sys", "efd3", "wchan", "owner", "ocnt", "waiters", "ref",
                    "in_check", "cb", "flush", "ready", "prio", "flags",
                    "owner_eq_idle", "tasks",
                ) if k in s}
                nows.append(slim | {"at": round(dt, 2)})
        holes.append({
            "gap_ms": round(gap, 1),
            "flip": f[:4],
            "qcb_def": q[:6],
            "nview": n[:4],
            "kind": "nview-late" if late_n and not early_n and early_q else (
                "nview-ok" if early_n else "other"),
            "at_qcb": nows[:3],
        })

    def summary(xs: list[float]) -> dict:
        gaps = [1000.0 * (b - a) for a, b in zip(xs, xs[1:]) if b >= a]
        over = [g for g in gaps if g > 50]
        span = (xs[-1] - xs[0]) if len(xs) > 1 else 0
        return {
            "n": len(xs),
            "hz": round(len(xs) / span, 2) if span else 0,
            "gt50": len(over),
            "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        }

    owners = Counter(s.get("owner") for s in snaps)
    sys_all = Counter(s.get("sys") for s in snaps)
    ocnt = Counter(s.get("ocnt") for s in snaps)
    wait = Counter("wait" if s.get("waiters") not in (None, "0x0") else "nowait" for s in snaps)
    inch = Counter(s.get("in_check") for s in snaps)
    cbz = Counter("cb" if s.get("cb") not in (None, "0x0") else "empty" for s in snaps)
    flush = Counter(s.get("flush") for s in snaps)
    ready = Counter(s.get("ready") for s in snaps)
    eq = Counter(s.get("owner_eq_idle") for s in snaps)

    out = {
        "kind": "qcb-ctx",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "ctx": hex(ctx),
        "src": hex(src),
        "idle": idle,
        "kick": summary(kick),
        "qcb_def": len(qcbd),
        "snaps": len(snaps),
        "sys_all": dict(sys_all),
        "owners": dict(owners),
        "ocnt": dict(ocnt),
        "waiters": dict(wait),
        "in_check": dict(inch),
        "cb": dict(cbz),
        "flush": dict(flush),
        "ready": {str(k): v for k, v in ready.items()},
        "owner_eq_idle": dict(eq),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-qcb-ctx.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main() -> int:
    extra = [a for a in sys.argv[1:] if a != "--host"]
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-qcb-ctx-sample.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-qcb-ctx-sample.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-qcb-ctx-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-qcb-ctx.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
    return r.returncode


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--host"]
    seconds = 8.0
    if args:
        try:
            seconds = float(args[0])
        except ValueError:
            pass
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    return on_device(seconds)


if __name__ == "__main__":
    raise SystemExit(main())
