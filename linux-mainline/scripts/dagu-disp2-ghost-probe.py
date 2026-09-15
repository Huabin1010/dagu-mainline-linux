#!/usr/bin/env python3
"""DISP2 ghost: one clock or two? finish_frame assign vs swap vs ifgl empty?

No poke. From host: python3 linux-mainline/scripts/dagu-disp2-ghost-probe.py --host
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

# clutter
OFF_CSCHED = "0x675a0"
OFF_DISP = "0x73c0c"
OFF_NPRES = "0x67cc4"
# mutter-18
OFF_IFGL = "0x1c4380"
OFF_IFGL_NULL = "0x1c4404"
OFF_NVIEW = "0x1c4440"
OFF_FF_ASGN = "0x1dd064"
OFF_SWAP = "0x1c4bb4"
OFF_MPOST = "0x1c1b20"

STOCK = {
    0x1C4404: 0xD65F03C0,
    0x1C2230: 0xD2800003,
    0x1D6F28: 0xD65F03C0,
    0x1D2B80: 0x00000000,
    0x1BD348: 0xF9400681,
    0x1DD128: 0x17FFFFC9,
    0x1DCFA8: 0x52800021,
    0x1DD050: 0x52800001,
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


def map_base(pid: int, needle: str) -> int:
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" in line:
            continue
        return int(line.split("-", 1)[0], 16)
    raise SystemExit(f"no base {needle}")


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


def parse_trace(raw: str) -> tuple[list[float], list[dict]]:
    kick: list[float] = []
    evs: list[dict] = []
    for line in raw.splitlines():
        if line[:1] == "#":
            continue
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
        name = None
        for n in (
            "dagu_csched", "dagu_disp", "dagu_npres", "dagu_ifgl_null",
            "dagu_ifgl", "dagu_nview", "dagu_ffasgn", "dagu_swap", "dagu_mpost",
        ):
            if f"{n}:" in line:
                name = n
                break
        if not name:
            continue
        evs.append({
            "t": ts,
            "n": name,
            "clk": parse_hex_field(line, "clock"),
            "st": parse_hex_field(line, "st"),
            "pend": parse_hex_field(line, "pend"),
            "next": parse_hex_field(line, "next"),
            "posted": parse_hex_field(line, "posted"),
            "ons": parse_hex_field(line, "ons"),
        })
    return kick, evs


def rel(evs: list[dict], t0: float, lo: float, hi: float) -> list[dict]:
    out = []
    for e in evs:
        if not (lo <= e["t"] <= hi):
            continue
        rec = {"dt": round((e["t"] - t0) * 1000.0, 2), "n": e["n"]}
        if e["clk"] is not None:
            rec["clk"] = hex(e["clk"])
        if e["st"] is not None:
            rec["st"] = e["st"]
        if e["pend"] is not None:
            rec["pend"] = e["pend"]
        if e["next"] is not None:
            rec["next"] = hex(e["next"])
        if e["posted"] is not None:
            rec["posted"] = hex(e["posted"])
        if e["ons"] is not None:
            rec["ons"] = hex(e["ons"])
        out.append(rec)
    return out


def verify_stock(shell: int) -> dict:
    base = map_base(shell, "libmutter-18.so.0.0.0")
    bad = {}
    with open(f"/proc/{shell}/mem", "rb", buffering=0) as mem:
        for off, want in STOCK.items():
            mem.seek(base + off)
            got = int.from_bytes(mem.read(4), "little")
            if got != want:
                bad[hex(off)] = {"want": hex(want), "got": hex(got)}
    return {"base": hex(base), "bad": bad}


def install(shell: int) -> list[str]:
    clutter = map_rx(shell, "libmutter-clutter-18.so")
    mutter = map_rx(shell, "libmutter-18.so.0.0.0")
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
    lines = [
        f"p:dagu_csched {clutter}:{OFF_CSCHED} clock=%x0 st=+88(%x0):u32 pend=+396(%x0):u32\n",
        f"p:dagu_disp {clutter}:{OFF_DISP} clock=%x0 st=+88(%x0):u32\n",
        f"p:dagu_npres {clutter}:{OFF_NPRES} clock=%x0 st=+88(%x0):u32 pend=+396(%x0):u32\n",
        f"p:dagu_ifgl {mutter}:{OFF_IFGL} ons=%x0 next=+88(%x0):u64 posted=+72(%x0):u64\n",
        f"p:dagu_ifgl_null {mutter}:{OFF_IFGL_NULL}\n",
        f"p:dagu_nview {mutter}:{OFF_NVIEW}\n",
        f"p:dagu_ffasgn {mutter}:{OFF_FF_ASGN}\n",
        f"p:dagu_swap {mutter}:{OFF_SWAP}\n",
        f"p:dagu_mpost {mutter}:{OFF_MPOST}\n",
    ]
    installed = []
    fd = os.open(str(ue), os.O_WRONLY | os.O_APPEND)
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
    stock = verify_stock(shell)
    installed = install(shell)
    (TR / "tracing_on").write_text("1\n")
    time.sleep(seconds)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()
    kick, evs = parse_trace(raw)
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        holes.append({
            "gap_ms": round(gap, 1),
            "pre": rel(evs, a, a - 0.010, a + 0.002),
            "inside": rel(evs, a, a + 0.002, b - 0.002),
            "close": rel(evs, a, b - 0.012, b + 0.004),
        })
    gaps = [1000.0 * (b - a) for a, b in zip(kick, kick[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (kick[-1] - kick[0]) if len(kick) > 1 else 0
    clk_n = Counter(e["clk"] for e in evs if e["clk"] is not None)
    name_n = Counter(e["n"] for e in evs)
    st_n = Counter((e["n"], e["st"]) for e in evs if e["st"] is not None)
    ifgl_next = Counter(
        (0 if (e["next"] or 0) == 0 else 1, 0 if (e["posted"] or 0) == 0 else 1)
        for e in evs if e["n"] == "dagu_ifgl"
    )
    out = {
        "kind": "disp2-ghost",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "stock": stock,
        "installed": installed,
        "kick_n": len(kick),
        "hz": round(len(kick) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        "counts": dict(name_n),
        "clocks": {hex(k): v for k, v in clk_n.most_common(8)},
        "state_hist": {f"{n}/st{st}": c for (n, st), c in st_n.most_common(24)},
        "ifgl_next_posted": {f"next{n}_posted{p}": c for (n, p), c in ifgl_next.items()},
        "holes": holes[:8],
    }
    Path("/tmp/dagu-disp2-ghost.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-disp2-ghost-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-disp2-ghost-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-disp2-ghost-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-disp2-ghost.json", str(dest)], check=False)
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
