#!/usr/bin/env python3
"""Sample gnome-shell main only in the qcb→nview gap.

Type B: flip/qcb on time, nview 65–90 ms late. No SIGSTOP.
From host: python3 linux-mainline/scripts/dagu-qcb-gap-sample.py --host
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import struct
from collections import Counter
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")

SITES = {
    "dagu_qcb": ("libmutter-18.so.0.0.0", "0x1d6e40"),
    "dagu_inv": ("libmutter-18.so.0.0.0", "0x1b9548"),
    "dagu_nview": ("libmutter-18.so.0.0.0", "0x1c4440"),
    "dagu_atomic": ("libmutter-18.so.0.0.0", "0x1b4878"),
}


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def find_pids() -> tuple[int, int, int]:
    shell = lab = kms = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell") and b"--mode=ubuntu" in cmd:
            shell = int(p.name)
            for tid_p in (p / "task").iterdir():
                try:
                    comm = (tid_p / "comm").read_text().strip()
                except OSError:
                    continue
                if comm == "KMS thread":
                    kms = int(tid_p.name)
        elif cmd.startswith(b"python") and b"dagu-native-lab.py" in cmd:
            lab = int(p.name)
    if shell is None or lab is None:
        raise SystemExit(json.dumps({"err": "need ubuntu+lab", "shell": shell, "lab": lab}))
    return shell, lab, kms


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


def load_maps(pid: int) -> list[tuple[int, int, int, str]]:
    out = []
    for line in open(f"/proc/{pid}/maps"):
        parts = line.split()
        lo, hi = (int(x, 16) for x in parts[0].split("-"))
        perm, off = parts[1], int(parts[2], 16)
        if "x" not in perm:
            continue
        path = parts[-1] if len(parts) > 5 else ""
        out.append((lo, hi, off, path))
    return out


def resolve(maps, pc: int | None) -> str:
    if not pc:
        return "?"
    for lo, hi, off, path in maps:
        if lo <= pc < hi:
            name = path.rsplit("/", 1)[-1] if path.startswith("/") else path or "anon"
            return f"{name}+{pc - lo + off:#x}"
    return hex(pc)


def read_sys_pc(pid: int) -> tuple[str, int | None, list[str]]:
    try:
        raw = Path(f"/proc/{pid}/syscall").read_text().strip()
    except OSError:
        return "gone", None, []
    if raw == "running":
        try:
            stat = Path(f"/proc/{pid}/stat").read_text()
            fields = stat[stat.rfind(")") + 2 :].split()
            return "running", int(fields[27]), []
        except (OSError, IndexError, ValueError):
            return "running", None, []
    parts = raw.split()
    pc = None
    if len(parts) >= 9:
        try:
            pc = int(parts[-1], 16)
        except ValueError:
            pc = None
    return parts[0], pc, parts


def read_timespec_ms(pid: int, addr: int) -> float | None:
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
    return sec * 1000.0 + nsec / 1e6


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def install(shell: int) -> list[str]:
    (TR / "tracing_on").write_text("0\n")
    en0 = TR / "events/uprobes/enable"
    if en0.is_file():
        en0.write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("16384\n")
    ue = TR / "uprobe_events"
    try:
        ue.write_text("")
    except OSError:
        time.sleep(0.05)
        ue.write_text("")
    maps = {"libmutter-18.so.0.0.0": map_rx(shell, "libmutter-18.so.0.0.0")}
    installed = []
    fd = os.open(str(ue), os.O_WRONLY | os.O_APPEND)
    try:
        for name, (lib, off) in SITES.items():
            try:
                os.write(fd, f"p:{name} {maps[lib]}:{off}\n".encode())
                installed.append(name)
            except OSError as e:
                installed.append(f"{name}:FAIL:{e}")
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")
    return installed


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


def resolve_fd(pid: int, fd: int) -> str:
    try:
        return os.readlink(f"/proc/{pid}/fd/{fd}")
    except OSError:
        return "?"


def read_pollfds(pid: int, addr: int, nfds: int) -> list[dict]:
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
        fd, events, revents = struct.unpack_from("<iHH", raw, i * 8)
        out.append({
            "fd": fd,
            "ev": events,
            "rev": revents,
            "p": resolve_fd(pid, fd) if fd >= 0 else "",
        })
    return out


def on_device(seconds: float = 8.0) -> int:
    shell, lab, kms = find_pids()
    smaps = load_maps(shell)
    installed = install(shell)
    (TR / "tracing_on").write_text("1\n")
    samples = []
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
        t = time.clock_gettime(time.CLOCK_MONOTONIC)
        sysn, pc, parts = read_sys_pc(shell)
        rec = {
            "t": t,
            "sys": sysn,
            "pc": resolve(smaps, pc) if pc else None,
            "wchan": Path(f"/proc/{shell}/wchan").read_text().strip()[:48]
            if Path(f"/proc/{shell}/wchan").exists() else "",
        }
        if sysn == "73" and len(parts) >= 4:
            try:
                rec["nfds"] = int(parts[2], 16)
                rec["tmo"] = read_timespec_ms(shell, int(parts[3], 16))
                rec["fds"] = read_pollfds(shell, int(parts[1], 16), rec["nfds"])
            except ValueError:
                pass
        samples.append(rec)
        time.sleep(0.0008)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()

    kick: list[float] = []
    flip: list[float] = []
    evs: list[dict] = []
    for line in raw.splitlines():
        ts = parse_ts(line)
        if ts is None:
            continue
        if "dpu_enc_kickoff:" in line:
            kick.append(ts)
            continue
        if "dpu_crtc_complete_flip:" in line:
            flip.append(ts)
            continue
        tid = None
        parts = line.split()
        if parts:
            comm = parts[0]
            if "-" in comm:
                try:
                    tid = int(comm.rsplit("-", 1)[1])
                except ValueError:
                    tid = None
        for name in SITES:
            if f"{name}:" in line:
                evs.append({"t": ts, "n": name, "tid": tid})
                break

    def rel(xs: list[float], t0: float, lo: float, hi: float) -> list[float]:
        return [round((x - t0) * 1000.0, 2) for x in xs if lo <= x <= hi]

    def rel_e(name: str, t0: float, lo: float, hi: float) -> list[dict]:
        out = []
        for e in evs:
            if e["n"] != name or not (lo <= e["t"] <= hi):
                continue
            rec = {"dt": round((e["t"] - t0) * 1000.0, 2)}
            if e.get("tid") is not None:
                rec["tid"] = e["tid"]
                rec["who"] = (
                    "main" if e["tid"] == shell
                    else "kms" if e["tid"] == kms
                    else "other"
                )
            out.append(rec)
        return out

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        qcb = rel_e("dagu_qcb", a, a - 0.004, b + 0.002)
        inv = rel_e("dagu_inv", a, a - 0.004, b + 0.002)
        nview = rel_e("dagu_nview", a, a - 0.004, b + 0.002)
        atomic = rel_e("dagu_atomic", a, a - 0.004, b + 0.002)
        qcb_early = [x for x in qcb if 2 <= x["dt"] <= 15]
        nview_early = [x for x in nview if 2 <= x["dt"] <= 15]
        nview_late = [x for x in nview if x["dt"] >= 40]
        atomic_early = [x for x in atomic if 2 <= x["dt"] <= 15]
        if qcb_early and nview_late and not nview_early:
            kind = "qcb-early-nview-late"
        elif atomic_early and not nview_early:
            kind = "atomic-early-nview-late"
        elif atomic_early:
            kind = "post-on-time"
        elif nview_early and not atomic_early:
            kind = "nview-no-post"
        else:
            kind = "no-early-qcb"
        qcb_t0 = next((x["dt"] for x in qcb_early), None)
        nview_t1 = next((x["dt"] for x in (nview_late or nview)), None)
        lo_s = a + ((qcb_t0 or 3.0) / 1000.0) + 0.0005
        if kind == "qcb-early-nview-late" and nview_t1 is not None:
            hi_s = a + (nview_t1 / 1000.0) - 0.0005
        elif kind == "nview-no-post":
            first_at = next((x["dt"] for x in atomic if x["dt"] >= 20), None)
            hi_s = a + ((first_at or gap) / 1000.0) - 0.0005
        else:
            hi_s = b - 0.002
        pc_c: Counter[str] = Counter()
        sys_c: Counter[str] = Counter()
        wchan_c: Counter[str] = Counter()
        tmos: list[float] = []
        fd_snap = None
        n_samp = 0
        for s in samples:
            if not (lo_s <= s["t"] <= hi_s):
                continue
            n_samp += 1
            sys_c[s["sys"]] += 1
            if s.get("wchan"):
                wchan_c[s["wchan"]] += 1
            if s.get("pc"):
                pc_c[s["pc"]] += 1
            if s.get("tmo") is not None:
                tmos.append(s["tmo"])
            if fd_snap is None and s.get("fds"):
                fd_snap = s["fds"]
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "flip": rel(flip, a, a - 0.008, b + 0.004),
            "qcb": qcb[:8] + qcb[-3:],
            "inv": inv[:8] + inv[-3:],
            "nview": nview[:6],
            "atomic": atomic[:6],
            "gap_lo_ms": round((lo_s - a) * 1000.0, 2),
            "gap_hi_ms": round((hi_s - a) * 1000.0, 2),
            "samp_n": n_samp,
            "sys": sys_c.most_common(5),
            "wchan": wchan_c.most_common(4),
            "pc": pc_c.most_common(8),
            "tmo_ms": [round(x, 1) for x in tmos[:3] + tmos[-2:]],
            "fds": fd_snap,
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

    out = {
        "kind": "qcb-gap",
        "shell": shell,
        "lab": lab,
        "kms": kms,
        "seconds": seconds,
        "installed": installed,
        "sample_n": len(samples),
        "kick": summary(kick),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-qcb-gap.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-qcb-gap-sample.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-qcb-gap-sample.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-qcb-gap-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-qcb-gap.json", str(dest)], check=False)
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
