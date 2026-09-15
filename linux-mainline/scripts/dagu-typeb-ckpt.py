#!/usr/bin/env python3
"""Type B: three stock-mutter checkpoints vs 80–200 ms dpu_enc_kickoff holes.

No poke. Stock libmutter only (md5 49a6422fcc5f11ba4894fa6dd82116b1).

  1 apply  0x165124  Mutter 收到了 GTK 的 wl_surface.commit（apply_state）
  2 sched  0x16517c  Wayland 把这张图标成需要刷新（bl schedule_update）
  3 disp   0x73c0c   FrameClock 真正 dispatch

洞里 32 ms 内：
  1 有 2 有 3 没有 → FRAMECLOCK（钟预测/调度把下一拍拦了）
  1 有 2 没有     → WAYLAND（协议状态没标刷新）
  1 没有           → GTK（解冻后其实没交图）
  三个都有仍有洞   → DISPATCHED_NO_KICK（钟跑了但没变成 kickoff）

bpftrace 0.25 cannot resolve those file offsets (static / mid-function).
Kernel uprobe_events attaches; bpftrace consumes tracepoint:uprobes:dagu_*
plus dpu_enc_kickoff. 3 忽略 kick 后 10 ms 内的上一帧残留 dispatch。
探针税不当验收。

On tablet: python3 /tmp/dagu-typeb-ckpt.py 12
From host: python3 linux-mainline/scripts/dagu-typeb-ckpt.py --host
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
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
BT_SRC = Path(__file__).with_name("dagu-typeb-ckpt.bt")
STOCK_MD5 = "49a6422fcc5f11ba4894fa6dd82116b1"
APPLY_OFF = 0x165124
SCHED_OFF = 0x16517C
DISP_OFF = 0x73C0C
# live-poke of apply-wakeup (bl cave). Stock is a bl to schedule_update@plt.
POKED_SCHED = 0x9401B681
EARLY_MS = 32.0
DISP_SKIP_MS = 10.0
HOLE_LO = 80.0
HOLE_HI = 200.0

SITES = {
    "dagu_apply": ("libmutter-18.so.0.0.0", hex(APPLY_OFF)),
    "dagu_sched": ("libmutter-18.so.0.0.0", hex(SCHED_OFF)),
    "dagu_disp": ("libmutter-clutter-18.so", hex(DISP_OFF)),
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
        elif b"dagu-native-lab.py" in cmd and b"--host" not in cmd and b"--measure" not in cmd:
            lab = int(p.name)
    if shell is None or lab is None:
        raise SystemExit(json.dumps({"err": "need ubuntu+lab", "shell": shell, "lab": lab}))
    return shell, lab


def map_rx(pid: int, needle: str) -> tuple[str, int]:
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" in line:
            continue
        rng = line.split()[0]
        base = int(rng.split("-", 1)[0], 16)
        mf = f"/proc/{pid}/map_files/{rng}"
        if Path(mf).exists():
            return mf, base
    raise SystemExit(f"no r-xp {needle} pid={pid}")


def md5_file(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def u32(pid: int, addr: int) -> int:
    with open(f"/proc/{pid}/mem", "rb", buffering=0) as f:
        f.seek(addr)
        b = f.read(4)
    return struct.unpack("<I", b)[0] if len(b) == 4 else 0


def is_bl(word: int) -> bool:
    return (word >> 26) == 0x25


def verify_stock(shell: int) -> dict:
    mu, mbase = map_rx(shell, "libmutter-18.so.0.0.0")
    cl, cbase = map_rx(shell, "libmutter-clutter-18.so")
    digest = md5_file(mu)
    apply_w = u32(shell, mbase + APPLY_OFF)
    sched_w = u32(shell, mbase + SCHED_OFF)
    disp_w = u32(shell, cbase + DISP_OFF)
    err = None
    if digest != STOCK_MD5:
        err = f"libmutter md5 {digest} != stock {STOCK_MD5}; refuse (offsets moved)"
    elif sched_w == POKED_SCHED:
        err = "0x16517c is apply-wakeup poke; restore stock, do not uprobe"
    elif not is_bl(sched_w):
        err = f"0x16517c={sched_w:#x} is not bl; not stock apply_state"
    out = {
        "mutter": mu,
        "clutter": cl,
        "mbase": hex(mbase),
        "cbase": hex(cbase),
        "md5": digest,
        "apply_insn": hex(apply_w),
        "sched_insn": hex(sched_w),
        "disp_insn": hex(disp_w),
    }
    if err:
        raise SystemExit(json.dumps({"err": err, **out}))
    return out


def bpftrace_script(shell: int, mutter: str, clutter: str) -> str:
    del mutter, clutter
    return BT_SRC.read_text().replace("__MAIN_PID__", str(shell))


def parse_bt(raw: str) -> dict:
    holes = []
    kinds: Counter[str] = Counter()
    end = None
    for line in raw.splitlines():
        if line.startswith("HOLE "):
            rec = {}
            for tok in line.split():
                if "=" not in tok:
                    continue
                k, v = tok.split("=", 1)
                if k == "verdict":
                    rec[k] = v
                elif k == "gap":
                    rec["gap_ms"] = int(v)
                else:
                    rec[k] = int(v)
            if "verdict" in rec:
                kinds[rec["verdict"]] += 1
                holes.append(rec)
        elif line.startswith("END "):
            end = line
    return {"holes": holes, "kinds": dict(kinds), "end": end}


def run_bpftrace(shell: int, info: dict, seconds: float) -> tuple[str, str]:
    bt_path = Path("/tmp/dagu-typeb-ckpt.live.bt")
    bt_path.write_text(bpftrace_script(shell, info["mutter"], info["clutter"]))
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")
    cmd = [
        "timeout", "-s", "INT", str(max(3, int(seconds))),
        "bpftrace", str(bt_path),
    ]
    p = subprocess.run(cmd, check=False, capture_output=True, text=True)
    return p.stdout, (p.stderr or "") + f"\nrc={p.returncode}\n"


def install_ftrace(shell: int, info: dict) -> list[str]:
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
    maps = {
        "libmutter-18.so.0.0.0": info["mutter"],
        "libmutter-clutter-18.so": info["clutter"],
    }
    installed = []
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        for name, (lib, off) in SITES.items():
            line = f"p:{name} {maps[lib]}:{off}\n"
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


def clear_ftrace() -> None:
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def parse_ftrace(raw: str) -> tuple[list[float], dict[str, list[float]]]:
    kick: list[float] = []
    ev: dict[str, list[float]] = {n: [] for n in SITES}
    for line in raw.splitlines():
        ts = parse_ts(line)
        if ts is None:
            continue
        if "dpu_enc_kickoff:" in line:
            kick.append(ts)
            continue
        for name in SITES:
            if f"{name}:" in line:
                ev[name].append(ts)
                break
    return kick, ev


def first_after(xs: list[float], t0: float, lo_ms: float, hi_ms: float) -> float | None:
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 1)
    return None


def verdict(apply_ms: float | None, sched_ms: float | None, disp_ms: float | None) -> str:
    h1 = apply_ms is not None and apply_ms < EARLY_MS
    h2 = sched_ms is not None and sched_ms < EARLY_MS
    h3 = disp_ms is not None and disp_ms < EARLY_MS
    if not h1:
        return "GTK"
    if not h2:
        return "WAYLAND"
    if not h3:
        return "FRAMECLOCK"
    return "DISPATCHED_NO_KICK"


def classify_ftrace(kick: list[float], ev: dict[str, list[float]]) -> dict:
    holes = []
    kinds: Counter[str] = Counter()
    mid = 0
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if 50 <= gap < HOLE_LO:
            mid += 1
            continue
        if gap < HOLE_LO or gap > HOLE_HI:
            continue
        apply_ms = first_after(ev["dagu_apply"], a, 0.0, gap - 2)
        sched_ms = first_after(ev["dagu_sched"], a, 0.0, gap - 2)
        disp_ms = first_after(ev["dagu_disp"], a, DISP_SKIP_MS, gap - 2)
        rec = {
            "gap_ms": round(gap, 1),
            "apply": 9999 if apply_ms is None else apply_ms,
            "sched": 9999 if sched_ms is None else sched_ms,
            "disp": 9999 if disp_ms is None else disp_ms,
            "verdict": verdict(apply_ms, sched_ms, disp_ms),
        }
        kinds[rec["verdict"]] += 1
        holes.append(rec)
    span = (kick[-1] - kick[0]) if len(kick) > 1 else 0
    return {
        "holes": holes,
        "kinds": dict(kinds),
        "mid50": mid,
        "kick": {
            "n": len(kick),
            "hz": round(len(kick) / span, 2) if span else 0,
        },
        "counts": {k: len(v) for k, v in ev.items()},
    }


def kick_summary_from_bt(raw: str, seconds: float) -> dict:
    m = re.search(r"kick=(\d+)", raw)
    n = int(m.group(1)) if m else 0
    return {"n": n, "hz": round(n / seconds, 2) if seconds else 0}


def on_device(seconds: float = 12.0) -> int:
    shell, lab = find_pids()
    info = verify_stock(shell)
    # bpftrace 0.25 cannot attach uprobe:so:offset for static apply_state
    # or the mid-function BL. Kernel uprobe_events can; bpftrace then
    # consumes tracepoint:uprobes:dagu_* with dpu_enc_kickoff.
    bt_out = bt_err = ""
    installed = install_ftrace(shell, info)
    engine = "bpftrace+uprobe"
    classified: dict
    if shutil.which("bpftrace"):
        bt_out, bt_err = run_bpftrace(shell, info, seconds)
        classified = parse_bt(bt_out)
        classified["kick"] = kick_summary_from_bt(
            bt_out + "\n" + (classified.get("end") or ""), seconds
        )
        classified["counts"] = {}
        if "apply=" in (classified.get("end") or ""):
            em = classified["end"]
            for key in ("apply", "sched", "disp"):
                m = re.search(rf"{key}=(\d+)", em)
                if m:
                    classified["counts"][f"dagu_{key}"] = int(m.group(1))
        attach_fail = (
            "ERROR:" in bt_err
            or "does not exist" in bt_err
            or "typeb-ckpt MAIN=" not in bt_out
        )
        if attach_fail:
            engine = "ftrace-fallback"
    else:
        engine = "ftrace-fallback"
        bt_err = "no bpftrace"
    if engine != "bpftrace+uprobe":
        (TR / "trace").write_text("")
        (TR / "tracing_on").write_text("1\n")
        time.sleep(seconds)
        (TR / "tracing_on").write_text("0\n")
        raw = (TR / "trace").read_text(errors="replace")
        classified = classify_ftrace(*parse_ftrace(raw))
        info["bpftrace_err"] = bt_err[-2000:] if bt_err else None
    classified["installed"] = installed
    clear_ftrace()
    out = {
        "kind": "typeb-ckpt",
        "engine": engine,
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "sites": {
            "1_apply": "meta_wayland_actor_surface_apply_state 0x165124",
            "2_sched": "apply_state bl clutter_stage_schedule_update 0x16517c",
            "3_disp": "clutter_frame_clock_dispatch 0x73c0c",
        },
        "stock": info,
        "kick": classified.get("kick"),
        "counts": classified.get("counts"),
        "kinds": classified.get("kinds"),
        "holes": classified.get("holes"),
        "mid50": classified.get("mid50"),
        "installed": classified.get("installed"),
        "end": classified.get("end"),
        "note": "probe tax; not an acceptance run",
    }
    Path("/tmp/dagu-typeb-ckpt.json").write_text(json.dumps(out, indent=2) + "\n")
    Path("/tmp/dagu-typeb-ckpt.btout").write_text(bt_out + "\n--- stderr ---\n" + bt_err)
    print(json.dumps(out, indent=2))
    return 0


def host_main(seconds: float) -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-typeb-ckpt.py"], check=True)
    subprocess.run(scp + [str(BT_SRC), f"root@{HOST}:/tmp/dagu-typeb-ckpt.bt"], check=True)
    r = subprocess.run(
        ssh + [f"python3 /tmp/dagu-typeb-ckpt.py {seconds}"],
        check=False,
    )
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-typeb-ckpt-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-typeb-ckpt.json", str(dest)], check=False)
    subprocess.run(
        scp + [f"root@{HOST}:/tmp/dagu-typeb-ckpt.btout", str(dest.with_suffix(".btout"))],
        check=False,
    )
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
    return r.returncode


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--host"]
    seconds = 12.0
    if args:
        try:
            seconds = float(args[0])
        except ValueError:
            pass
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main(seconds)
    return on_device(seconds)


if __name__ == "__main__":
    raise SystemExit(main())
