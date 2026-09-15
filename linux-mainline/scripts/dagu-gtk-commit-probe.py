#!/usr/bin/env python3
"""Hole-align mutter sendcb/apply/dec vs GTK request_phase/gsk_render.

No poke. From host: python3 linux-mainline/scripts/dagu-gtk-commit-probe.py --host
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

MUTTER = {
    "dagu_sendcb": "0x1673f0",
    "dagu_apply": "0x165124",
    "dagu_dec": "0x167e80",
}
CLUTTER = {
    "dagu_sched": "0x675a0",
    "dagu_fcdisp": "0x73c0c",
}
GTK = {
    "dagu_reqph": "0x5733d0",
    "dagu_qrender": "0x5a3010",
    "dagu_gsk": "0x5dfc40",
}
GJS = {
    "dagu_gjs_cave": "0xb00a0",
}
MOZ = {
    "dagu_slice": "0x62dda0",
}
MUTTER_MORE = {
    "dagu_updarea": "0x160f6c",  # update_area: mtk_region_is_empty
    "dagu_xflush": "0x125400",
}


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


def parse_trace(raw: str) -> dict[str, list[float]]:
    ev = {k: [] for k in list(MUTTER) + list(CLUTTER) + list(GTK)
          + list(GJS) + list(MOZ) + list(MUTTER_MORE) + ["kick"]}
    for line in raw.splitlines():
        ts = None
        for tok in line.split():
            if tok.endswith(":") and tok[:-1].replace(".", "", 1).isdigit():
                ts = float(tok[:-1])
                break
        if ts is None:
            continue
        if "dpu_enc_kickoff:" in line:
            ev["kick"].append(ts)
            continue
        for name in ev:
            if name != "kick" and f"{name}:" in line:
                ev[name].append(ts)
    return ev


def rel(xs: list[float], t0: float, lo: float, hi: float) -> list[float]:
    return [round((x - t0) * 1000.0, 2) for x in xs if lo <= x <= hi]


def thread_snap(pid: int) -> dict[str, str]:
    out = {}
    tdir = Path(f"/proc/{pid}/task")
    try:
        tids = list(tdir.iterdir())
    except OSError:
        return out
    for t in tids:
        try:
            comm = (t / "comm").read_text().strip()
            sysc = (t / "syscall").read_text().strip().split()[0]
        except OSError:
            continue
        if comm in ("python3", "gmain", "python3:gdrv0", "python3:ir3q0",
                    "gnome-shell", "gdbus") or sysc not in ("73", "98"):
            out[f"{t.name}:{comm}"] = sysc
    return out


def install(shell: int, lab: int) -> list[str]:
    mf = map_rx(shell, "libmutter-18.so.0.0.0")
    cmf = map_rx(shell, "libmutter-clutter-18.so")
    gmf = map_rx(lab, "libgtk-4.so")
    gjmf = map_rx(shell, "libgjs.so")
    mzmf = map_rx(shell, "libmozjs-140")
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
        for name, off, path in (
            *[(n, o, mf) for n, o in MUTTER.items()],
            *[(n, o, cmf) for n, o in CLUTTER.items()],
            *[(n, o, gmf) for n, o in GTK.items()],
            *[(n, o, gjmf) for n, o in GJS.items()],
            *[(n, o, mzmf) for n, o in MOZ.items()],
            *[(n, o, mf) for n, o in MUTTER_MORE.items()],
        ):
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
    return installed


def clear() -> None:
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds: float = 8.0) -> int:
    shell, lab = find_pids()
    installed = install(shell, lab)
    samples = []
    (TR / "tracing_on").write_text("1\n")
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
        t = time.clock_gettime(time.CLOCK_MONOTONIC)
        rec = {"t": t}
        try:
            rec["sh"] = Path(f"/proc/{shell}/syscall").read_text().strip().split()[0]
        except OSError:
            rec["sh"] = "gone"
        try:
            rec["lab"] = Path(f"/proc/{lab}/syscall").read_text().strip().split()[0]
        except OSError:
            rec["lab"] = "gone"
        rec["th"] = thread_snap(lab)
        samples.append(rec)
        time.sleep(0.003)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()
    ev = parse_trace(raw)
    kick = ev["kick"]
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        sh_c: Counter[str] = Counter()
        lab_c: Counter[str] = Counter()
        th_c: Counter[str] = Counter()
        n = 0
        for s in samples:
            if not (a + 0.006 <= s["t"] <= b - 0.006):
                continue
            n += 1
            sh_c[s["sh"]] += 1
            lab_c[s["lab"]] += 1
            for k, v in s["th"].items():
                if v == "running" or (not k.endswith(":python3") and v not in ("73", "98")):
                    th_c[f"{k}={v}"] += 1
        holes.append({
            "gap_ms": round(gap, 1),
            "n": n,
            "sh": sh_c.most_common(3),
            "lab": lab_c.most_common(3),
            "th_busy": th_c.most_common(8),
            "pre": {k: rel(ev[k], a, a - 0.008, a + 0.002)
                    for k in ("dagu_sendcb", "dagu_apply", "dagu_dec",
                              "dagu_gsk", "dagu_fcdisp")},
            "inside": {k: rel(ev[k], a, a + 0.002, b - 0.002)
                       for k in ("dagu_sendcb", "dagu_apply", "dagu_dec",
                                 "dagu_reqph", "dagu_qrender", "dagu_gsk",
                                 "dagu_sched", "dagu_fcdisp", "dagu_gjs_cave",
                                 "dagu_slice", "dagu_updarea", "dagu_xflush")},
            "inside_n": {k: len(rel(ev[k], a, a + 0.002, b - 0.002))
                         for k in ("dagu_gjs_cave", "dagu_slice",
                                   "dagu_updarea", "dagu_xflush")},
            "close": {k: rel(ev[k], a, b - 0.02, b + 0.004)
                      for k in ("dagu_sendcb", "dagu_apply", "dagu_dec",
                                "dagu_sched", "dagu_fcdisp", "dagu_gsk")},
        })
    gaps = [1000.0 * (b - a) for a, b in zip(kick, kick[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (kick[-1] - kick[0]) if len(kick) > 1 else 0
    out = {
        "kind": "gtk-commit",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "counts": {k: len(v) for k, v in ev.items()},
        "kick_n": len(kick),
        "hz": round(len(kick) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        "holes": holes,
    }
    Path("/tmp/dagu-gtk-commit.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-gtk-commit-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-gtk-commit-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-gtk-commit-{stamp}.json"
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-gtk-commit.json", str(dest)], check=False)
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
