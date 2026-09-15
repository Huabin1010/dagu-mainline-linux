#!/usr/bin/env python3
"""Type B: GLib g_main_dispatch enter/leave with a nest stack.

Live glib 2.88: dispatch blr x27 at 0x606f4, next insn 0x606f8 is leave.
Does not hook apply-wakeup 0x16517c or qcb 0x1d6e40.
From host: python3 linux-mainline/scripts/dagu-glib-enter-leave-probe.py --host
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
        elif cmd.startswith(b"python") and b"dagu-native-lab.py" in cmd:
            lab = int(p.name)
    if shell is None or lab is None:
        raise SystemExit(json.dumps({"err": "need ubuntu+lab", "shell": shell, "lab": lab}))
    return shell, lab


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
    raise SystemExit(f"no r-xp {needle}")


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def parse_src(line: str) -> int | None:
    for tok in line.split():
        if tok.startswith("src="):
            try:
                return int(tok[4:], 16)
            except ValueError:
                return None
    return None


def _maps(pid: int) -> list[tuple[int, int, int, str]]:
    out = []
    for line in open(f"/proc/{pid}/maps"):
        parts = line.split()
        lo, hi = (int(x, 16) for x in parts[0].split("-"))
        off = int(parts[2], 16)
        path = parts[-1] if len(parts) > 5 else ""
        out.append((lo, hi, off, path))
    return out


def _reso(maps, p: int) -> str:
    for lo, hi, off, path in maps:
        if lo <= p < hi:
            name = path.rsplit("/", 1)[-1] if path.startswith("/") else path or "anon"
            return f"{name}+{p - lo + off:#x}"
    return hex(p)


def src_ident(pid: int, src: int, maps) -> dict:
    rec = {"src": hex(src)}
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
        mem.seek(src + 16)
        funcs = struct.unpack("<Q", mem.read(8))[0]
        mem.seek(src + 40)
        rec["prio"] = struct.unpack("<i", mem.read(4))[0]
        rec["flags"] = hex(struct.unpack("<I", mem.read(4))[0])
        rec["id"] = struct.unpack("<I", mem.read(4))[0]
        mem.seek(src + 80)
        namep = struct.unpack("<Q", mem.read(8))[0]
        name = ""
        if namep > 0x1000:
            mem.seek(namep)
            name = mem.read(64).split(b"\x00", 1)[0].decode("ascii", "replace")
        rec["name"] = name or "?"
        rec["funcs"] = _reso(maps, funcs)
        if funcs > 0x1000:
            mem.seek(funcs + 16)
            disp = struct.unpack("<Q", mem.read(8))[0]
            rec["dispatch"] = _reso(maps, disp)
        mem.close()
    except OSError:
        rec["mem"] = "fail"
    return rec


def install(shell: int) -> None:
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
    (TR / "buffer_size_kb").write_text("32768\n")
    mutter = map_rx(shell, "libmutter-18.so.0.0.0")
    glib = map_rx(shell, "libglib-2.0.so.0.8800.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_gs {glib}:0x606f4 src=%x19\n".encode())
        os.write(fd, f"p:dagu_ge {glib}:0x606f8\n".encode())
        os.write(fd, f"p:dagu_cbs {mutter}:0x1d5d00\n".encode())
        os.write(fd, f"p:dagu_nview {mutter}:0x1c4440\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")


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
    ke = TR / "events/dpu/dpu_enc_kickoff/enable"
    if ke.is_file():
        ke.write_text("1\n")
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds: float = 8.0) -> int:
    shell, lab = find_pids()
    install(shell)
    kick: list[float] = []
    flip: list[float] = []
    nview: list[float] = []
    cbs: list[float] = []
    stack: list[dict] = []
    kick_cover: dict[float, list[dict]] = {}
    finished: list[dict] = []
    n_gs = n_ge = n_mismatch = n_max_depth = 0
    maps = _maps(shell)
    ident_cache: dict[int, dict] = {}

    def ident(src: int | None) -> dict | None:
        if not src:
            return None
        if src not in ident_cache:
            ident_cache[src] = src_ident(shell, src, maps)
        return ident_cache[src]

    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    tag = f"-{shell} "
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
                is_shell = tag in line or f"-{shell}\t" in line
                if "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                    kick_cover[ts] = [
                        {
                            "src": hex(e["src"]) if e.get("src") else None,
                            "age_ms": round((ts - e["t"]) * 1000.0, 2),
                            "depth": i + 1,
                        }
                        for i, e in enumerate(stack)
                    ]
                    continue
                if "dpu_crtc_complete_flip:" in line:
                    flip.append(ts)
                    continue
                if not is_shell:
                    continue
                if "dagu_gs:" in line:
                    n_gs += 1
                    src = parse_src(line)
                    stack.append({"t": ts, "src": src})
                    if len(stack) > n_max_depth:
                        n_max_depth = len(stack)
                elif "dagu_ge:" in line:
                    n_ge += 1
                    if not stack:
                        n_mismatch += 1
                        continue
                    e = stack.pop()
                    dt = (ts - e["t"]) * 1000.0
                    rec = {
                        "t": e["t"],
                        "leave": ts,
                        "dt": round(dt, 2),
                        "src": e["src"],
                    }
                    if dt >= 2.0:
                        rec["ident"] = ident(e["src"])
                        finished.append(rec)
                elif "dagu_nview:" in line:
                    nview.append(ts)
                elif "dagu_cbs:" in line:
                    cbs.append(ts)
    finally:
        pipe.close()
    (TR / "tracing_on").write_text("0\n")
    open_left = [
        {"src": hex(e["src"]) if e.get("src") else None, "age_ms": None, "open": True}
        for e in stack
    ]
    clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        f = [round((x - a) * 1000.0, 2) for x in flip if a - 0.008 <= x <= b + 0.002]
        n = [round((x - a) * 1000.0, 2) for x in nview if a - 0.006 <= x <= b + 0.002]
        c = [round((x - a) * 1000.0, 2) for x in cbs if a - 0.006 <= x <= b + 0.002]
        early_f = [x for x in f if -2 <= x <= 15]
        early_n = [x for x in n if -2 <= x <= 15]
        late_n = [x for x in n if x >= 40]
        if late_n and early_f and not early_n:
            kind = "B-nview-late"
        elif early_n and not early_f:
            kind = "kick-late"
        elif early_n:
            kind = "nview-ok-post-late"
        else:
            kind = "other"
        cover = kick_cover.get(a, [])
        covering_done = []
        for d in finished:
            if d["t"] <= a + 0.008 and d["leave"] >= a:
                idented = d.get("ident") or ident(d["src"])
                covering_done.append({
                    "enter_ms": round((d["t"] - a) * 1000.0, 2),
                    "leave_ms": round((d["leave"] - a) * 1000.0, 2),
                    "dt": d["dt"],
                    "name": (idented or {}).get("name"),
                    "prio": (idented or {}).get("prio"),
                    "dispatch": (idented or {}).get("dispatch"),
                    "src": hex(d["src"]) if d.get("src") else None,
                })
        in_hole_long = []
        for d in finished:
            if a < d["t"] < b and d["dt"] >= 8.0:
                idented = d.get("ident") or ident(d["src"])
                in_hole_long.append({
                    "enter_ms": round((d["t"] - a) * 1000.0, 2),
                    "leave_ms": round((d["leave"] - a) * 1000.0, 2),
                    "dt": d["dt"],
                    "name": (idented or {}).get("name"),
                    "prio": (idented or {}).get("prio"),
                    "dispatch": (idented or {}).get("dispatch"),
                })
        inner_leave = covering_done[-1]["leave_ms"] if covering_done else None
        first_n = n[0] if n else None
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "flip": f[:4],
            "nview": n[:4],
            "cbs": c[:6],
            "ncover_at_kick": len(cover),
            "cover_at_kick": cover[:6],
            "covering_leave": covering_done[-3:] if covering_done else [],
            "nview_minus_inner_leave": (
                round(first_n - inner_leave, 2)
                if first_n is not None and inner_leave is not None
                else None
            ),
            "in_hole_ge8": in_hole_long[:6],
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

    ncover0 = sum(1 for h in holes if h["ncover_at_kick"] == 0)
    ncover1 = sum(1 for h in holes if h["ncover_at_kick"] > 0)
    out = {
        "kind": "glib-enter-leave",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_gs": n_gs,
        "n_ge": n_ge,
        "n_mismatch": n_mismatch,
        "max_depth": n_max_depth,
        "open_at_end": open_left,
        "long_ge2": len(finished),
        "long_names": Counter(
            ((d.get("ident") or {}).get("name"), (d.get("ident") or {}).get("prio"))
            for d in finished
            if d.get("dt", 0) >= 8
        ).most_common(12),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes_ncover0": ncover0,
        "holes_ncover_gt0": ncover1,
        "holes": holes[:10],
    }
    Path("/tmp/dagu-glib-enter-leave.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-glib-enter-leave-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-glib-enter-leave-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-glib-enter-leave-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(
            ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/events/dpu/dpu_enc_kickoff/enable; echo 1 > /sys/kernel/debug/tracing/tracing_on'"],
            check=True,
        )
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-glib-enter-leave.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(
        ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/events/dpu/dpu_enc_kickoff/enable; echo 1 > /sys/kernel/debug/tracing/tracing_on'"],
        check=False,
    )
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
