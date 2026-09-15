#!/usr/bin/env python3
"""When paint_view or swap_buffers exceeds 8ms, sample gnome-shell syscall/wchan.

No poke. From host: python3 linux-mainline/scripts/dagu-paint-swap-wait-probe.py --host
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


def load_maps(pid: int) -> list[tuple[int, int, int, str]]:
    out = []
    for line in open(f"/proc/{pid}/maps"):
        parts = line.split()
        lo, hi = (int(x, 16) for x in parts[0].split("-"))
        if "x" not in parts[1]:
            continue
        off = int(parts[2], 16)
        path = parts[-1] if len(parts) > 5 else ""
        out.append((lo, hi, off, path))
    return out


def resolve(maps, pc: int) -> str:
    for lo, hi, off, path in maps:
        if lo <= pc < hi:
            name = path.rsplit("/", 1)[-1] if path.startswith("/") else path or "anon"
            return f"{name}+{pc - lo + off:#x}"
    return hex(pc)


def sample(pid: int, maps) -> dict:
    rec: dict = {}
    try:
        rec["wchan"] = Path(f"/proc/{pid}/wchan").read_text().strip()
    except OSError:
        rec["wchan"] = "?"
    try:
        rec["syscall"] = Path(f"/proc/{pid}/syscall").read_text().strip()
    except OSError:
        rec["syscall"] = "?"
    try:
        raw = Path(f"/proc/{pid}/stat").read_text()
        rpar = raw.rfind(")")
        fields = raw[rpar + 2 :].split()
        rec["state"] = fields[0]
        pc = int(fields[27])
        rec["pc"] = resolve(maps, pc) if pc else "0"
    except (OSError, IndexError, ValueError):
        rec["pc"] = "?"
    try:
        rec["kstack"] = [
            ln.strip() for ln in Path(f"/proc/{pid}/stack").read_text().splitlines()[:8]
        ]
    except OSError:
        rec["kstack"] = []
    return rec


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def install(shell: int) -> list[str]:
    mu = map_rx(shell, "libmutter-18.so.0.0.0")
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
    (TR / "buffer_size_kb").write_text("8192\n")
    lines = [
        f"p:dagu_pe {mu}:0xc52a8\n",
        f"p:dagu_pr {mu}:0xc52ac\n",
        f"p:dagu_se {mu}:0xc5a34\n",
        f"p:dagu_sr {mu}:0xc5a38\n",
    ]
    installed = []
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        for line in lines:
            name = line.split(":", 2)[1].split()[0]
            try:
                os.write(fd, line.encode())
                installed.append(name)
            except OSError as e:
                installed.append(f"{name}:FAIL:{e}")
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
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
    maps = load_maps(shell)
    installed = install(shell)
    kick: list[float] = []
    waits: list[dict] = []
    open_ev: dict[str, float] = {}
    sampled: dict[str, bool] = {}
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    tag = f"-{shell}"
    try:
        os.set_blocking(pipe.fileno(), False)
        buf = ""
        while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
            now = time.clock_gettime(time.CLOCK_MONOTONIC)
            for kind, t0 in list(open_ev.items()):
                if now - t0 >= 0.008 and not sampled.get(kind):
                    rec = sample(shell, maps)
                    rec["kind"] = kind
                    rec["open_ms"] = round((now - t0) * 1000.0, 2)
                    waits.append(rec)
                    sampled[kind] = True
            try:
                chunk = pipe.read(65536)
            except BlockingIOError:
                chunk = ""
            if not chunk:
                time.sleep(0.0003)
                continue
            buf += chunk
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                ts = parse_ts(line)
                if ts is None:
                    continue
                if "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                    continue
                if tag not in line:
                    continue
                if "dagu_pe:" in line:
                    open_ev["paint"] = ts
                    sampled["paint"] = False
                elif "dagu_pr:" in line and "paint" in open_ev:
                    dt = (ts - open_ev.pop("paint")) * 1000.0
                    if dt >= 8.0:
                        waits.append({"kind": "paint_done", "dt": round(dt, 2)})
                    sampled.pop("paint", None)
                elif "dagu_se:" in line:
                    open_ev["swap"] = ts
                    sampled["swap"] = False
                elif "dagu_sr:" in line and "swap" in open_ev:
                    dt = (ts - open_ev.pop("swap")) * 1000.0
                    if dt >= 8.0:
                        waits.append({"kind": "swap_done", "dt": round(dt, 2)})
                    sampled.pop("swap", None)
    finally:
        pipe.close()
    (TR / "tracing_on").write_text("0\n")
    clear()
    gaps = [1000.0 * (b - a) for a, b in zip(kick, kick[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (kick[-1] - kick[0]) if len(kick) > 1 else 0
    sys_n = Counter(
        (w.get("kind"), (w.get("syscall") or "?").split()[0], w.get("wchan"))
        for w in waits if "syscall" in w
    )
    out = {
        "kind": "paint-swap-wait",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "kick_n": len(kick),
        "hz": round(len(kick) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        "wait_n": len(waits),
        "wait_sys": {f"{k}/{s}/{w}": c for (k, s, w), c in sys_n.most_common(12)},
        "waits": waits[:16],
    }
    Path("/tmp/dagu-paint-swap-wait.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-paint-swap-wait-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-paint-swap-wait-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-paint-swap-wait-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-paint-swap-wait.json", str(dest)], check=False)
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
