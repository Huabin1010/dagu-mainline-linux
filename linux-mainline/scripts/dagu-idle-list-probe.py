#!/usr/bin/env python3
"""At ifgl next==NULL, is compositor frame_callback_surfaces empty?

after_update 0x1696bc x20=compositor, list at +88.
No poke. From host: python3 linux-mainline/scripts/dagu-idle-list-probe.py --host
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


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def u64(mem, addr: int) -> int:
    mem.seek(addr)
    b = mem.read(8)
    return struct.unpack("<Q", b)[0] if len(b) == 8 else 0


def glist_len(mem, head: int) -> int:
    n = 0
    seen = set()
    p = head
    while p and p not in seen and n < 32:
        seen.add(p)
        n += 1
        p = u64(mem, p + 8)  # GList.next
    return n


def install(shell: int) -> list[str]:
    mu = map_rx(shell, "libmutter-18.so.0.0.0")
    cl = map_rx(shell, "libmutter-clutter-18.so")
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
        f"p:dagu_au {mu}:0x1696bc comp=%x20 list=+88(%x20):u64 view=%x24\n",
        f"p:dagu_ifn {mu}:0x1c4404\n",
        f"p:dagu_nview {mu}:0x1c4440\n",
        f"p:dagu_send {mu}:0x1673f0\n",
        f"p:dagu_npres {cl}:0x67cc4 clock=%x0 st=+88(%x0):u32 pend=+396(%x0):u32\n",
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
    installed = install(shell)
    mem = open(f"/proc/{shell}/mem", "rb", buffering=0)
    kick: list[float] = []
    evs: list[dict] = []
    comp = 0
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    tag = f"-{shell}"
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
                    continue
                if tag not in line:
                    continue
                rec: dict = {"t": ts}
                if "dagu_au:" in line:
                    rec["n"] = "au"
                    rec["comp"] = parse_hex_field(line, "comp")
                    rec["list"] = parse_hex_field(line, "list")
                    if rec["comp"]:
                        comp = rec["comp"]
                elif "dagu_ifn:" in line:
                    rec["n"] = "ifn"
                    if comp:
                        head = u64(mem, comp + 88)
                        rec["list"] = head
                        rec["nlist"] = glist_len(mem, head) if head else 0
                elif "dagu_nview:" in line:
                    rec["n"] = "nview"
                elif "dagu_send:" in line:
                    rec["n"] = "send"
                elif "dagu_npres:" in line:
                    rec["n"] = "npres"
                    rec["st"] = parse_hex_field(line, "st")
                    rec["pend"] = parse_hex_field(line, "pend")
                else:
                    continue
                evs.append(rec)
    finally:
        pipe.close()
        mem.close()
    (TR / "tracing_on").write_text("0\n")
    clear()

    def rel(t0: float, lo: float, hi: float) -> list[dict]:
        out = []
        for e in evs:
            if lo <= e["t"] <= hi:
                d = {"dt": round((e["t"] - t0) * 1000.0, 2), "n": e["n"]}
                for k in ("st", "pend", "nlist"):
                    if k in e and e[k] is not None:
                        d[k] = e[k]
                if e.get("list") is not None:
                    d["list"] = hex(e["list"])
                out.append(d)
        return out

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        holes.append({
            "gap_ms": round(gap, 1),
            "pre": rel(a, a - 0.008, a + 0.002),
            "inside": rel(a, a + 0.002, b - 0.002),
        })
    gaps = [1000.0 * (b - a) for a, b in zip(kick, kick[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (kick[-1] - kick[0]) if len(kick) > 1 else 0
    ifn = [e for e in evs if e.get("n") == "ifn"]
    au_empty = sum(1 for e in evs if e.get("n") == "au" and not e.get("list"))
    au_n = sum(1 for e in evs if e.get("n") == "au")
    out = {
        "kind": "idle-list",
        "shell": shell,
        "lab": lab,
        "comp": hex(comp) if comp else None,
        "installed": installed,
        "kick_n": len(kick),
        "hz": round(len(kick) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        "counts": dict(Counter(e.get("n") for e in evs)),
        "au_n": au_n,
        "au_list0": au_empty,
        "ifn_n": len(ifn),
        "ifn_nlist": [e.get("nlist") for e in ifn[:12]],
        "holes": holes[:6],
    }
    Path("/tmp/dagu-idle-list.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-idle-list-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-idle-list-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-idle-list-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-idle-list.json", str(dest)], check=False)
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
