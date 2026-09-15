#!/usr/bin/env python3
"""Time each GLib source dispatch (real blr at 0x606f4).

0x60b34 is prepare (funcs+0), not dispatch. Live glib 2.88:
  dispatch blr 0x606f4, x19=GSource, name at source+80.
From host: python3 linux-mainline/scripts/dagu-gsrc-long-probe.py --host
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
        elif cmd.startswith(b"python3\x00/usr/local/sbin/dagu-native-lab.py"):
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
            name = mem.read(48).split(b"\x00", 1)[0].decode("ascii", "replace")
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


def src_name(pid: int, src: int) -> str:
    try:
        ident = src_ident(pid, src, _maps(pid))
        return (
            f"{ident.get('name','?')}#id{ident.get('id')}@p{ident.get('prio')}"
            f"/{ident.get('dispatch') or ident.get('funcs')}"
        )
    except OSError:
        return hex(src)


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
        os.write(fd, f"p:dagu_idlecb {glib}:0x62408 x1=%x1\n".encode())
        os.write(fd, f"p:dagu_qcb {mutter}:0x1d6e40 x1=%x1\n".encode())
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
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds: float = 8.0) -> int:
    shell, lab = find_pids()
    install(shell)
    kick: list[float] = []
    flip: list[float] = []
    nview: list[float] = []
    qcbd: list[float] = []
    long_disp: list[dict] = []
    n_gs = n_ge = 0
    pending: float | None = None
    pending_src: int | None = None
    last_idle_x1: int | None = None
    maps = _maps(shell)
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
                if tag not in line and f"-{shell}\t" not in line:
                    if "dpu_enc_kickoff:" in line or "dpu_crtc_complete_flip:" in line:
                        ts = parse_ts(line)
                        if ts is None:
                            continue
                        if "dpu_enc_kickoff:" in line:
                            kick.append(ts)
                        else:
                            flip.append(ts)
                    continue
                ts = parse_ts(line)
                if ts is None:
                    continue
                if "dagu_idlecb:" in line:
                    for tok in line.split():
                        if tok.startswith("x1="):
                            try:
                                last_idle_x1 = int(tok[3:], 16)
                            except ValueError:
                                pass
                    continue
                if "dagu_gs:" in line:
                    n_gs += 1
                    pending = ts
                    pending_src = parse_src(line)
                elif "dagu_ge:" in line:
                    n_ge += 1
                    if pending is not None:
                        dt = (ts - pending) * 1000.0
                        if dt >= 2.0:
                            rec = {
                                "t": pending,
                                "dt": round(dt, 2),
                                "src": hex(pending_src) if pending_src else None,
                            }
                            if pending_src and dt >= 8.0:
                                rec["ident"] = src_ident(shell, pending_src, maps)
                                if last_idle_x1:
                                    rec["ident"]["idle_x1"] = _reso(maps, last_idle_x1)
                            long_disp.append(rec)
                    pending = None
                    pending_src = None
                elif "dagu_nview:" in line:
                    nview.append(ts)
                elif "dagu_qcb:" in line:
                    qcbd.append(ts)
                elif "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                elif "dpu_crtc_complete_flip:" in line:
                    flip.append(ts)
    finally:
        pipe.close()
    (TR / "tracing_on").write_text("0\n")
    names = {}
    for d in long_disp:
        s = d.get("src")
        if s and s not in names:
            try:
                names[s] = src_name(shell, int(s, 16))
            except ValueError:
                names[s] = s
        d["name"] = names.get(s, s)
    clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n = [round((x - a) * 1000.0, 2) for x in nview if a - 0.006 <= x <= b + 0.002]
        q = [round((x - a) * 1000.0, 2) for x in qcbd if a - 0.006 <= x <= b + 0.002]
        f = [round((x - a) * 1000.0, 2) for x in flip if a - 0.008 <= x <= b + 0.002]
        early_n = [x for x in n if -2 <= x <= 15]
        late_n = [x for x in n if x >= 40]
        longs = []
        for d in long_disp:
            dt = (d["t"] - a) * 1000.0
            if -10 <= dt <= gap + 2:
                longs.append({"at": round(dt, 2), "ms": d["dt"], "name": d.get("name")})
        holes.append({
            "gap_ms": round(gap, 1),
            "flip": f[:4],
            "qcb_def": q[:6],
            "nview": n[:4],
            "kind": "nview-late" if late_n and not early_n else (
                "nview-ok" if early_n else "other"),
            "long": longs[:8],
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

    by_name = Counter(d.get("name") for d in long_disp)
    out = {
        "kind": "gsrc-long",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_gs": n_gs,
        "n_ge": n_ge,
        "long_n": len(long_disp),
        "long_names": by_name.most_common(12),
        "long_max": sorted(long_disp, key=lambda d: d["dt"], reverse=True)[:8],
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-gsrc-long.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-gsrc-long-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-gsrc-long-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-gsrc-long-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=True)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-gsrc-long.json", str(dest)], check=False)
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
