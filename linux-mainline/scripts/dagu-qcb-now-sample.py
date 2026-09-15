#!/usr/bin/env python3
"""Sample gnome-shell main at onscreen qcb (x1==0), not later in the hole.

From host: python3 linux-mainline/scripts/dagu-qcb-now-sample.py --host
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
        path = line.split()[-1]
        if path.startswith("/"):
            return path
    raise SystemExit(f"no r-xp {needle} pid={pid}")


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def evcount(pid: int, fd: int) -> int | None:
    try:
        raw = Path(f"/proc/{pid}/fdinfo/{fd}").read_text()
    except OSError:
        return None
    for line in raw.splitlines():
        if line.startswith("eventfd-count:"):
            return int(line.split()[1], 16)
    return None


def read_sys(pid: int) -> tuple[str, list[str]]:
    try:
        raw = Path(f"/proc/{pid}/syscall").read_text().strip()
    except OSError:
        return "gone", []
    return raw.split()[0], raw.split()


def resolve_fd(pid: int, fd: int) -> str:
    try:
        return os.readlink(f"/proc/{pid}/fd/{fd}")
    except OSError:
        return "?"


def poll_fds(pid: int, addr: int, nfds: int) -> list[int]:
    if not addr or nfds <= 0 or nfds > 64:
        return []
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
        mem.seek(addr)
        raw = mem.read(8 * nfds)
        mem.close()
    except OSError:
        return []
    out = []
    for i in range(len(raw) // 8):
        fd, ev, rev = struct.unpack_from("<iHH", raw, i * 8)
        out.append(fd)
    return out


def tmo_ms(pid: int, addr: int) -> float | None:
    if not addr:
        return None
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
        mem.seek(addr)
        sec, nsec = struct.unpack("<qq", mem.read(16))
        mem.close()
    except OSError:
        return None
    if sec < 0:
        return -1.0
    return round(sec * 1000.0 + nsec / 1e6, 1)


def sample_main(pid: int) -> dict:
    sysn, parts = read_sys(pid)
    rec = {
        "sys": sysn,
        "efd3": evcount(pid, 3),
        "wchan": Path(f"/proc/{pid}/wchan").read_text().strip()[:40]
        if Path(f"/proc/{pid}/wchan").exists() else "",
    }
    if sysn == "73" and len(parts) >= 4:
        try:
            rec["nfds"] = int(parts[2], 16)
            rec["tmo"] = tmo_ms(pid, int(parts[3], 16))
            rec["fds"] = poll_fds(pid, int(parts[1], 16), rec["nfds"])
            rec["has3"] = 3 in rec["fds"]
        except ValueError:
            pass
    elif sysn == "running":
        try:
            stat = Path(f"/proc/{pid}/stat").read_text()
            eip = int(stat[stat.rfind(")") + 2 :].split()[27])
            rec["eip"] = hex(eip)
            for line in open(f"/proc/{pid}/maps"):
                if "x" not in line.split()[1]:
                    continue
                lo, hi = (int(x, 16) for x in line.split()[0].split("-"))
                if lo <= eip < hi:
                    path = line.split()[-1] if line.split()[-1].startswith("/") else "anon"
                    off = int(line.split()[2], 16) + (eip - lo)
                    rec["pc"] = f"{path.rsplit('/', 1)[-1]}+{off:#x}"
                    break
        except (OSError, IndexError, ValueError):
            pass
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
        os.write(fd, f"p:dagu_cbs {mf}:0x1d5d00\n".encode())
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
    install(shell)
    snaps: list[dict] = []
    kick: list[float] = []
    flip: list[float] = []
    qcb0: list[float] = []
    nview: list[float] = []
    cbs: list[float] = []
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
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
                elif "dagu_cbs:" in line:
                    cbs.append(ts)
                if "dagu_qcb:" not in line or "x1=0x0" not in line:
                    continue
                qcb0.append(ts)
                rec = sample_main(shell)
                rec["t"] = ts
                time.sleep(0.0003)
                rec["later"] = sample_main(shell)
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
        q = [round((x - a) * 1000.0, 2) for x in qcb0 if a - 0.006 <= x <= b + 0.002]
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
                nows.append({k: s[k] for k in s if k != "t"} | {"at": round(dt, 2)})
        holes.append({
            "gap_ms": round(gap, 1),
            "flip": f[:4],
            "qcb0": q[:6],
            "nview": n[:4],
            "kind": "nview-late" if late_n and not early_n and early_q else (
                "nview-ok" if early_n else "other"),
            "at_qcb0": nows[:4],
        })

    sys_all = Counter(s.get("sys") for s in snaps)
    later_sys = Counter((s.get("later") or {}).get("sys") for s in snaps)
    eips = Counter(s.get("pc") or s.get("eip") for s in snaps if s.get("sys") == "running")
    later_efd = Counter(
        "efd>0" if (s.get("later") or {}).get("efd3") else "efd0"
        for s in snaps
    )
    stay_poll = 0
    woke = 0
    for s in snaps:
        if s.get("sys") == "73" and (s.get("later") or {}).get("sys") == "running":
            woke += 1
        if s.get("sys") == "73" and (s.get("later") or {}).get("sys") == "73":
            stay_poll += 1
    has3 = Counter(
        ("has3" if s.get("has3") else ("no3" if s.get("sys") == "73" else s.get("sys")))
        for s in snaps
    )

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

    out = {
        "kind": "qcb-now",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "qcb0": len(qcb0),
        "snaps": len(snaps),
        "sys_all": dict(sys_all),
        "later_sys": dict(later_sys),
        "later_efd": dict(later_efd),
        "woke_from_poll": woke,
        "stay_poll": stay_poll,
        "eip": eips.most_common(8),
        "poll": dict(has3),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:8],
        "snap_head": snaps[:3],
    }
    Path("/tmp/dagu-qcb-now.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-qcb-now-sample.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-qcb-now-sample.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-qcb-now-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-qcb-now.json", str(dest)], check=False)
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
