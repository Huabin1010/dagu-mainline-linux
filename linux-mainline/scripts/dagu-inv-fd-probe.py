#!/usr/bin/env python3
"""Lean Type-B split: atomic/hev fd, invoke tid, nview vs kernel flip.

No poke. From host: python3 linux-mainline/scripts/dagu-inv-fd-probe.py --host
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")

SITES = {
    "dagu_atomic": ("libmutter-18.so.0.0.0", "0x1b4878", "fd"),
    "dagu_hev": ("libmutter-18.so.0.0.0", "0x1b1a2c", "fd"),
    "dagu_qcb": ("libmutter-18.so.0.0.0", "0x1d6e40", "plain"),
    "dagu_inv": ("libmutter-18.so.0.0.0", "0x1b9548", "plain"),
    "dagu_nview": ("libmutter-18.so.0.0.0", "0x1c4440", "plain"),
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
    if shell is None or lab is None or kms is None:
        raise SystemExit(json.dumps({
            "err": "need ubuntu+lab+kms", "shell": shell, "lab": lab, "kms": kms,
        }))
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
    raise SystemExit(f"no r-xp {needle}")


def parse_hex_field(line: str, key: str) -> int | None:
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0]
    try:
        return int(v, 16)
    except ValueError:
        return None


def parse_tid(line: str) -> int | None:
    head = line.split(" [", 1)[0].strip()
    if "-" not in head:
        return None
    try:
        return int(head.rsplit("-", 1)[1])
    except ValueError:
        return None


def card0_fds(pid: int) -> dict[int, str]:
    out = {}
    fd_dir = Path(f"/proc/{pid}/fd")
    for ent in fd_dir.iterdir():
        try:
            tgt = os.readlink(ent)
        except OSError:
            continue
        if tgt.endswith("/card0") or tgt == "/dev/dri/card0":
            out[int(ent.name)] = tgt
    return out


def kms_poll_fds(kms: int) -> list[str]:
    try:
        raw = Path(f"/proc/{kms}/syscall").read_text().strip().split()
    except OSError:
        return []
    return raw[:12]


def parse_trace(raw: str) -> tuple[list[float], list[float], list[dict]]:
    kick: list[float] = []
    flip: list[float] = []
    evs: list[dict] = []
    for line in raw.splitlines():
        ts = None
        for part in line.split():
            if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
                ts = float(part[:-1])
                break
        if ts is None:
            continue
        if "dpu_enc_kickoff:" in line:
            kick.append(ts)
            continue
        if "dpu_crtc_complete_flip:" in line:
            flip.append(ts)
            continue
        name = None
        for n in SITES:
            if f"{n}:" in line:
                name = n
                break
        if not name:
            continue
        evs.append({
            "t": ts,
            "n": name,
            "tid": parse_tid(line),
            "fd": parse_hex_field(line, "fd"),
        })
    return kick, flip, evs


def rel_ts(xs: list[float], t0: float, lo: float, hi: float) -> list[float]:
    return [round((x - t0) * 1000.0, 2) for x in xs if lo <= x <= hi]


def rel(evs: list[dict], t0: float, lo: float, hi: float) -> list[dict]:
    out = []
    for e in evs:
        if lo <= e["t"] <= hi:
            rec = {"dt": round((e["t"] - t0) * 1000.0, 2), "n": e["n"]}
            if e.get("tid") is not None:
                rec["tid"] = e["tid"]
            if e.get("fd") is not None:
                rec["fd"] = e["fd"]
            out.append(rec)
    return out


def classify(hole: dict, kms: int, main: int) -> str:
    inv = [e for e in hole["inside"] + hole["pre"] + hole["close"] if e["n"] == "dagu_inv"]
    nview = [e for e in hole["inside"] + hole["close"] if e["n"] == "dagu_nview"]
    hev = [e for e in hole["inside"] + hole["pre"] if e["n"] == "dagu_hev"]
    qcb = [e for e in hole["inside"] + hole["pre"] if e["n"] == "dagu_qcb"]
    flips = hole["flip"]
    early_flip = any(0 <= f <= 12 for f in flips)
    early_inv_kms = [e for e in inv if e.get("dt", 99) <= 12 and e.get("tid") == kms]
    late_inv_main = [e for e in inv if e.get("dt", 0) >= 40 and e.get("tid") == main]
    early_nview = [e for e in nview if e.get("dt", 99) <= 12]
    late_nview = [e for e in nview if e.get("dt", 0) >= 40]
    if early_flip and early_inv_kms and late_nview and late_inv_main:
        return "B-main"
    if early_flip and early_nview:
        return "B-kick-or-post"
    if early_flip and not hev and not qcb:
        return "B-kms-miss"
    if early_flip and qcb and not early_inv_kms:
        return "B-qcb-no-inv"
    return "other"


def install(shell: int) -> list[str]:
    path = map_rx(shell, "libmutter-18.so.0.0.0")
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
    installed = []
    fd = os.open(str(ue), os.O_WRONLY | os.O_APPEND)
    try:
        for name, (_lib, off, kind) in SITES.items():
            if kind == "fd":
                line = f"p:{name} {path}:{off} fd=%x0\n"
            else:
                line = f"p:{name} {path}:{off}\n"
            try:
                os.write(fd, line.encode())
                installed.append(name)
            except OSError as e:
                installed.append(f"{name}:FAIL:{e}")
    finally:
        os.close(fd)
    en = TR / "events/uprobes/enable"
    if not en.is_file():
        raise SystemExit(json.dumps({"err": "no uprobes", "installed": installed}))
    en.write_text("1\n")
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


def on_device(seconds: float = 8.0) -> int:
    shell, lab, kms = find_pids()
    fds = card0_fds(shell)
    kms_sys0 = kms_poll_fds(kms)
    installed = install(shell)
    (TR / "tracing_on").write_text("1\n")
    time.sleep(seconds)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()
    kick, flip, evs = parse_trace(raw)
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        h = {
            "gap_ms": round(gap, 1),
            "flip": rel_ts(flip, a, a - 0.008, b + 0.004),
            "pre": rel(evs, a, a - 0.008, a + 0.002),
            "inside": rel(evs, a, a + 0.002, b - 0.002),
            "close": rel(evs, a, b - 0.02, b + 0.004),
        }
        h["kind"] = classify(h, kms, shell)
        holes.append(h)

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

    fd_atomic = Counter(e["fd"] for e in evs if e["n"] == "dagu_atomic" and e["fd"] is not None)
    fd_hev = Counter(e["fd"] for e in evs if e["n"] == "dagu_hev" and e["fd"] is not None)
    inv_tid = Counter(e["tid"] for e in evs if e["n"] == "dagu_inv")
    nview_tid = Counter(e["tid"] for e in evs if e["n"] == "dagu_nview")
    hev_tid = Counter(e["tid"] for e in evs if e["n"] == "dagu_hev")
    out = {
        "kind": "inv-fd",
        "shell": shell,
        "lab": lab,
        "kms": kms,
        "seconds": seconds,
        "card0_fds": fds,
        "kms_syscall0": kms_sys0,
        "installed": installed,
        "kick": summary(kick),
        "flip": summary(flip),
        "counts": dict(Counter(e["n"] for e in evs)),
        "fd_atomic": {str(k): v for k, v in fd_atomic.items()},
        "fd_hev": {str(k): v for k, v in fd_hev.items()},
        "inv_tid": {str(k): v for k, v in inv_tid.items()},
        "nview_tid": {str(k): v for k, v in nview_tid.items()},
        "hev_tid": {str(k): v for k, v in hev_tid.items()},
        "hole_kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-inv-fd.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-inv-fd-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-inv-fd-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-inv-fd-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-inv-fd.json", str(dest)], check=False)
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
