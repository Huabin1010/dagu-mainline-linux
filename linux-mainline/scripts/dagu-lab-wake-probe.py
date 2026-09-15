#!/usr/bin/env python3
"""Type B IDLE hole: who wakes GTK ~100ms after present→IDLE?

Lab thaw (5a4da0) + request_phase vs mutter sendcb / empty-frame.
No poke. From host: python3 linux-mainline/scripts/dagu-lab-wake-probe.py --host
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

# gtk VA → caller of thaw (gdk_surface_thaw_updates)
THAW_CALLERS = {
    0x518A44: "wl_frame_cb",      # after bl 5a4da0
    0x516EA4: "force_commit",
    0x51B52C: "wl_51b528",
    0x51B538: "wl_51b534",
    0x51B544: "wl_51b540",
    0x5220E8: "wl_5220e4",
    0x522B4C: "wl_522b48",
    0x5237EC: "wl_5237e8",
    0x523B38: "wl_523b34",
    0x532CB0: "wl_532cac",
    0x533228: "wl_533224",
    0x5334D0: "wl_5334cc",
    0x547A40: "x11_or_idle",
    0x4F6DE4: "broadway",
    0x4FEABC: "broadway2",
}

# gtk VA → caller of gdk_frame_clock_request_phase
REQPH_CALLERS = {
    0x2418FC: "widget_qdraw",     # phase 4
    0x342508: "widget_0x40",
    0x3BA354: "widget_qdraw2",
    0x59FAF8: "surf_qrender",     # phase 0x10
    0x59FD48: "surf_layout",      # phase 8
    0x5A4D84: "thaw_idle",        # phase 1
    0x5A4EBC: "thaw_pending",
    0x5A5D2C: "surf_5a5d28",
    0x5A6D28: "surf_phase20",
}

SITES = {
    "dagu_sched": ("libmutter-clutter-18.so", "0x675a0", "clock"),
    "dagu_npresent": ("libmutter-clutter-18.so", "0x67cc4", "clock"),
    "dagu_nready": ("libmutter-clutter-18.so", "0x67be0", "clock"),
    "dagu_fcdisp": ("libmutter-clutter-18.so", "0x73c0c", "clock"),
    "dagu_sendcb": ("libmutter-18.so.0.0.0", "0x1673f0", "plain"),
    "dagu_emptydsp": ("libmutter-18.so.0.0.0", "0x167440", "plain"),
    "dagu_thaw": ("libgtk-4.so", "0x5a4da0", "thaw"),
    "dagu_reqph": ("libgtk-4.so", "0x5733d0", "reqph"),
    "dagu_gsk": ("libgtk-4.so", "0x5dfc40", "plain"),
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


def map_rx(pid: int, needle: str) -> tuple[int, str]:
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" in line:
            continue
        rng = line.split()[0]
        mf = f"/proc/{pid}/map_files/{rng}"
        if Path(mf).exists():
            return int(rng.split("-", 1)[0], 16), mf
    raise SystemExit(f"no r-xp {needle} pid={pid}")


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


def caller_name(lr: int | None, gtk_base: int, table: dict[int, str]) -> str | None:
    if lr is None or not gtk_base:
        return None
    va = lr - gtk_base
    if va in table:
        return table[va]
    for off, name in table.items():
        if abs(va - off) <= 8:
            return name
    return hex(va)


def parse_trace(raw: str, gtk_base: int) -> tuple[list[float], list[dict]]:
    kick: list[float] = []
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
        name = None
        for n in SITES:
            if f"{n}:" in line:
                name = n
                break
        if not name:
            continue
        rec = {
            "t": ts,
            "n": name,
            "clk": parse_hex_field(line, "arg1") or parse_hex_field(line, "clock"),
            "st": parse_hex_field(line, "st"),
            "pend": parse_hex_field(line, "pend"),
            "lr": parse_hex_field(line, "lr"),
            "ph": parse_hex_field(line, "ph"),
        }
        if name == "dagu_thaw":
            rec["who"] = caller_name(rec["lr"], gtk_base, THAW_CALLERS)
        elif name == "dagu_reqph":
            rec["who"] = caller_name(rec["lr"], gtk_base, REQPH_CALLERS)
        evs.append(rec)
    return kick, evs


def rel(evs: list[dict], t0: float, lo: float, hi: float) -> list[dict]:
    out = []
    for e in evs:
        if lo <= e["t"] <= hi:
            rec = {"dt": round((e["t"] - t0) * 1000.0, 2), "n": e["n"]}
            if e.get("clk") is not None:
                rec["clk"] = hex(e["clk"])
            if e.get("st") is not None:
                rec["st"] = e["st"]
            if e.get("pend") is not None:
                rec["pend"] = e["pend"]
            if e.get("who"):
                rec["who"] = e["who"]
            if e.get("ph") is not None:
                rec["ph"] = e["ph"]
            if e.get("lr") is not None and e["n"] in ("dagu_thaw", "dagu_reqph"):
                rec["lr"] = hex(e["lr"])
            out.append(rec)
    return out


def install(shell: int, lab: int) -> tuple[list[str], int]:
    maps = {
        "libmutter-clutter-18.so": map_rx(shell, "libmutter-clutter-18.so")[1],
        "libmutter-18.so.0.0.0": map_rx(shell, "libmutter-18.so.0.0.0")[1],
        "libgtk-4.so": map_rx(lab, "libgtk-4.so")[1],
    }
    gtk_base = map_rx(lab, "libgtk-4.so")[0]
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
        for name, (lib, off, kind) in SITES.items():
            path = maps[lib]
            if kind == "clock":
                line = (
                    f"p:{name} {path}:{off} clock=%x0 st=+88(%x0):u32 "
                    f"pend=+396(%x0):u32\n"
                )
            elif kind == "thaw":
                line = f"p:{name} {path}:{off} lr=%x30\n"
            elif kind == "reqph":
                line = f"p:{name} {path}:{off} lr=%x30 ph=%x1\n"
            else:
                line = f"p:{name} {path}:{off}\n"
            try:
                os.write(fd, line.encode())
                installed.append(name)
            except OSError as e:
                if kind in ("thaw", "reqph"):
                    try:
                        os.write(fd, f"p:{name} {path}:{off}\n".encode())
                        installed.append(f"{name}:nolr")
                        continue
                    except OSError as e2:
                        installed.append(f"{name}:FAIL:{e2}")
                        continue
                installed.append(f"{name}:FAIL:{e}")
    finally:
        os.close(fd)
    en = TR / "events/uprobes/enable"
    if not en.is_file():
        raise SystemExit(json.dumps({"err": "no uprobes", "installed": installed}))
    en.write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    return installed, gtk_base


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
    # confirm GDK after_paint still stock
    gtk_base, _ = map_rx(lab, "libgtk-4.so")
    with open(f"/proc/{lab}/mem", "rb") as mem:
        mem.seek(gtk_base + 0x518cc8)
        gdk_op = int.from_bytes(mem.read(4), "little")
    installed, gtk_base = install(shell, lab)
    (TR / "tracing_on").write_text("1\n")
    time.sleep(seconds)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()
    kick, evs = parse_trace(raw, gtk_base)
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        holes.append({
            "gap_ms": round(gap, 1),
            "pre": rel(evs, a, a - 0.008, a + 0.002),
            "inside": rel(evs, a, a + 0.002, b - 0.002),
            "close": rel(evs, a, b - 0.02, b + 0.004),
        })
    gaps = [1000.0 * (b - a) for a, b in zip(kick, kick[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (kick[-1] - kick[0]) if len(kick) > 1 else 0
    name_n = Counter(e["n"] for e in evs)
    who_n = Counter(e.get("who") or "?" for e in evs if e["n"] == "dagu_thaw")
    req_who = Counter(e.get("who") or "?" for e in evs if e["n"] == "dagu_reqph")
    out = {
        "kind": "lab-wake",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "gdk_518cc8": hex(gdk_op),
        "gtk_base": hex(gtk_base),
        "installed": installed,
        "kick_n": len(kick),
        "hz": round(len(kick) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        "counts": dict(name_n),
        "thaw_who": dict(who_n),
        "reqph_who": dict(req_who),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-lab-wake.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-lab-wake-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-lab-wake-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-lab-wake-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-lab-wake.json", str(dest)], check=False)
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
