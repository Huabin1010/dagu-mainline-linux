#!/usr/bin/env python3
"""Type B hole: ppoll timespec + clock GSource ready_time/context.

No extra wakeup poke. Align who computed the ~100ms timeout.
From host: python3 linux-mainline/scripts/dagu-ppoll-timeout-probe.py --host
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

# glib 2.88: GSource.context +32, flags +0x2c bit6=SOURCE_BLOCKED,
# ready_time = *(GSource+88)+16. Clock GSource via clutter clock+72.
# g_main_context_default slot: glib VA 0x180a90 (bss).
GLIB_DEFAULT_SLOT = 0x180A90
CLOCK_SOURCE = 72
SOURCE_CTX = 32
SOURCE_FLAGS = 0x2C
SOURCE_PRIV = 88
PRIV_READY = 16
SCHED = 0x675A0


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


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


def read_pc_stat(pid: int) -> int | None:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    rpar = raw.rfind(")")
    fields = raw[rpar + 2 :].split()
    try:
        return int(fields[27])
    except (IndexError, ValueError):
        return None


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
        raise SystemExit(json.dumps({"err": "need ubuntu-shell+lab",
                                     "shell": shell, "lab": lab}))
    return shell, lab


def map_rx(pid: int, needle: str) -> tuple[int, str]:
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        rng = line.split()[0]
        base = int(rng.split("-", 1)[0], 16)
        mf = f"/proc/{pid}/map_files/{rng}"
        if Path(mf).exists():
            return base, mf
    raise SystemExit(f"no r-xp {needle}")


def parse_ppoll(raw: str) -> dict:
    raw = raw.strip()
    if raw == "running":
        return {"sys": "running", "tmo_ms": None, "tsp": None, "fds": None, "nfds": None}
    parts = raw.split()
    if not parts:
        return {"sys": "empty", "tmo_ms": None, "tsp": None, "fds": None, "nfds": None}
    nr = parts[0]
    if nr != "73":
        return {"sys": nr, "tmo_ms": None, "tsp": None, "fds": None, "nfds": None}
    fds = nfds = tsp = None
    try:
        if len(parts) >= 2:
            fds = int(parts[1], 16)
        if len(parts) >= 3:
            nfds = int(parts[2], 16)
        if len(parts) >= 4:
            tsp = int(parts[3], 16)
    except ValueError:
        return {"sys": "73", "tmo_ms": None, "tsp": None, "fds": fds, "nfds": nfds}
    if tsp == 0:
        return {"sys": "73", "tmo_ms": -1, "tsp": 0, "fds": fds, "nfds": nfds}
    return {"sys": "73", "tmo_ms": None, "tsp": tsp, "fds": fds, "nfds": nfds}


def fd_name(pid: int, fd: int) -> str:
    try:
        return os.readlink(f"/proc/{pid}/fd/{fd}")
    except OSError:
        return "?"


def read_pollfds(pid: int, fds_ptr: int, nfds: int, limit: int = 12) -> list[str]:
    if not fds_ptr or nfds is None or nfds < 0:
        return []
    n = min(int(nfds), limit)
    out = []
    try:
        with open(f"/proc/{pid}/mem", "rb", buffering=0) as pm:
            pm.seek(fds_ptr)
            raw = pm.read(8 * n)
    except OSError:
        return []
    for i in range(len(raw) // 8):
        fd, events, revents = struct.unpack_from("<ihh", raw, i * 8)
        if fd < 0:
            continue
        out.append(f"{fd}:{fd_name(pid, fd)}:e{events:x}:r{revents:x}")
    return out


def peek_clock(mem, clock: int, now_us: int) -> dict:
    mem.seek(clock + CLOCK_SOURCE)
    src = struct.unpack("<Q", mem.read(8))[0]
    if src < 0x10000:
        return {"clock": hex(clock), "src": hex(src), "bad": True}
    mem.seek(src + SOURCE_CTX)
    ctx = struct.unpack("<Q", mem.read(8))[0]
    mem.seek(src + SOURCE_FLAGS)
    flags = struct.unpack("<I", mem.read(4))[0]
    mem.seek(src + SOURCE_PRIV)
    priv = struct.unpack("<Q", mem.read(8))[0]
    mem.seek(src + 104)
    tfd = struct.unpack("<I", mem.read(4))[0]
    ready = None
    if priv >= 0x10000:
        mem.seek(priv + PRIV_READY)
        ready = struct.unpack("<q", mem.read(8))[0]
    ready_delta_ms = None
    if ready is not None and ready > 0:
        ready_delta_ms = round((ready - now_us) / 1000.0, 2)
    return {
        "clock": hex(clock),
        "src": hex(src),
        "ctx": hex(ctx),
        "flags": hex(flags),
        "blocked": bool(flags & (1 << 6)),
        "priv": hex(priv),
        "tfd": tfd,
        "ready": ready,
        "ready_delta_ms": ready_delta_ms,
    }


def install_uprobes(cmf: str, gmf: str) -> list[str]:
    (TR / "tracing_on").write_text("0\n")
    en0 = TR / "events/uprobes/enable"
    if en0.is_file():
        en0.write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("8192\n")
    ue = TR / "uprobe_events"
    try:
        ue.write_text("")
    except OSError:
        time.sleep(0.05)
        if en0.is_file():
            en0.write_text("0\n")
        ue.write_text("")
    installed = []
    fd = os.open(str(ue), os.O_WRONLY | os.O_APPEND)
    try:
        for line in (
            f"p:dagu_sched {cmf}:{hex(SCHED)} clk=%x0\n",
        ):
            try:
                os.write(fd, line.encode())
                installed.append(line.split(":", 1)[1].split()[0])
            except OSError as e:
                installed.append(f"FAIL:{line.strip()}:{e}")
    finally:
        os.close(fd)
    en = TR / "events/uprobes/enable"
    if not en.is_file():
        raise SystemExit(json.dumps({"err": "no uprobes", "installed": installed}))
    en.write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    return installed


def clear_uprobes() -> None:
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
    smaps = load_maps(shell)
    lmaps = load_maps(lab)
    clutter_base, cmf = map_rx(shell, "libmutter-clutter-18.so")
    glib_base, gmf = map_rx(shell, "libglib-2.0.so")
    mem = open(f"/proc/{shell}/mem", "rb", buffering=0)
    mem.seek(glib_base + GLIB_DEFAULT_SLOT)
    default_ctx = struct.unpack("<Q", mem.read(8))[0]
    installed = install_uprobes(cmf, gmf)
    (TR / "tracing_on").write_text("1\n")
    time.sleep(0.4)
    boot = (TR / "trace").read_text(errors="replace")
    clock = 0
    for line in boot.splitlines():
        if "dagu_sched:" not in line:
            continue
        for tok in line.split():
            if tok.startswith("clk="):
                try:
                    clock = int(tok.split("=", 1)[1], 16)
                except ValueError:
                    pass
    (TR / "trace").write_text("")

    samples = []
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
        t = time.clock_gettime(time.CLOCK_MONOTONIC)
        now_us = int(t * 1_000_000)
        try:
            sh_raw = Path(f"/proc/{shell}/syscall").read_text()
        except OSError:
            sh_raw = "gone"
        try:
            lab_raw = Path(f"/proc/{lab}/syscall").read_text()
        except OSError:
            lab_raw = "gone"
        rec = parse_ppoll(sh_raw)
        lab_rec = parse_ppoll(lab_raw)
        for item, pid in ((rec, shell), (lab_rec, lab)):
            if item.get("tsp"):
                try:
                    with open(f"/proc/{pid}/mem", "rb", buffering=0) as pm:
                        pm.seek(item["tsp"])
                        sec, nsec = struct.unpack("<qq", pm.read(16))
                    item["tmo_ms"] = round(sec * 1000.0 + nsec / 1_000_000.0, 3)
                except (OSError, struct.error):
                    item["tmo_ms"] = "unreadable"
            if item.get("fds") and item.get("nfds"):
                item["poll"] = read_pollfds(pid, item["fds"], item["nfds"])
        clk = None
        if clock:
            try:
                clk = peek_clock(mem, clock, now_us)
            except (OSError, struct.error):
                clk = {"err": "peek"}
        sh_pc = lab_pc = None
        if rec.get("sys") == "running":
            sh_pc = read_pc_stat(shell)
        if lab_rec.get("sys") == "running":
            lab_pc = read_pc_stat(lab)
        # syscall file also has pc as last field when sleeping
        if rec.get("sys") != "running":
            parts = sh_raw.split()
            if len(parts) >= 9:
                try:
                    sh_pc = int(parts[-1], 16)
                except ValueError:
                    pass
        if lab_rec.get("sys") != "running":
            parts = lab_raw.split()
            if len(parts) >= 9:
                try:
                    lab_pc = int(parts[-1], 16)
                except ValueError:
                    pass
        samples.append({
            "t": t,
            "sh": rec.get("sys"),
            "tmo_ms": rec.get("tmo_ms"),
            "lab": lab_rec.get("sys"),
            "lab_tmo_ms": lab_rec.get("tmo_ms"),
            "sh_poll": rec.get("poll") or [],
            "lab_poll": lab_rec.get("poll") or [],
            "sh_pc": sh_pc,
            "lab_pc": lab_pc,
            "clk": clk,
        })
        time.sleep(0.002)

    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear_uprobes()
    mem.close()

    kick = []
    sched_clk = []
    for line in raw.splitlines():
        if "dpu_enc_kickoff:" in line:
            for tok in line.split():
                if tok.endswith(":") and tok[:-1].replace(".", "", 1).isdigit():
                    kick.append(float(tok[:-1]))
                    break
        if "dagu_sched:" in line:
            for tok in line.split():
                if tok.startswith("clk="):
                    try:
                        sched_clk.append(int(tok.split("=", 1)[1], 16))
                    except ValueError:
                        pass
    if sched_clk:
        clock = Counter(sched_clk).most_common(1)[0][0]

    # backfill clock peek using last known; samples already have clk if we
    # discovered clock mid-window. If not, note it.
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        sh_sys: Counter[str] = Counter()
        tmo_c: Counter[str] = Counter()
        lab_sys: Counter[str] = Counter()
        lab_tmo_c: Counter[str] = Counter()
        ready_c: Counter[str] = Counter()
        ready_raw: Counter[str] = Counter()
        blocked_c: Counter[str] = Counter()
        sh_pc_c: Counter[str] = Counter()
        lab_pc_c: Counter[str] = Counter()
        sh_poll_c: Counter[str] = Counter()
        lab_poll_c: Counter[str] = Counter()
        n = 0
        for s in samples:
            if not (a + 0.006 <= s["t"] <= b - 0.006):
                continue
            n += 1
            sh_sys[str(s["sh"])] += 1
            tmo_c[str(s["tmo_ms"])] += 1
            lab_sys[str(s["lab"])] += 1
            lab_tmo_c[str(s["lab_tmo_ms"])] += 1
            clk = s.get("clk") or {}
            if clk.get("ready") is not None:
                ready_raw[str(clk["ready"])] += 1
            if clk.get("ready_delta_ms") is not None:
                ready_c[str(clk["ready_delta_ms"])] += 1
            if "blocked" in clk:
                blocked_c[str(clk["blocked"])] += 1
            if s.get("sh_pc"):
                sh_pc_c[resolve(smaps, s["sh_pc"])] += 1
            if s.get("lab_pc"):
                lab_pc_c[resolve(lmaps, s["lab_pc"])] += 1
            if s.get("sh_poll"):
                sh_poll_c["|".join(s["sh_poll"])] += 1
            if s.get("lab_poll"):
                lab_poll_c["|".join(s["lab_poll"])] += 1
        holes.append({
            "gap_ms": round(gap, 1),
            "n": n,
            "sh_sys": sh_sys.most_common(4),
            "tmo_ms": tmo_c.most_common(8),
            "lab_sys": lab_sys.most_common(4),
            "lab_tmo_ms": lab_tmo_c.most_common(8),
            "ready": ready_raw.most_common(4),
            "ready_delta_ms": ready_c.most_common(6),
            "blocked": blocked_c.most_common(4),
            "sh_pc": sh_pc_c.most_common(6),
            "lab_pc": lab_pc_c.most_common(6),
            "sh_poll": sh_poll_c.most_common(3),
            "lab_poll": lab_poll_c.most_common(3),
        })

    gaps = [1000.0 * (b - a) for a, b in zip(kick, kick[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (kick[-1] - kick[0]) if len(kick) > 1 else 0
    last_clk = None
    for s in reversed(samples):
        if s.get("clk") and not s["clk"].get("bad"):
            last_clk = s["clk"]
            break
    if last_clk is None and clock:
        try:
            mem2 = open(f"/proc/{shell}/mem", "rb", buffering=0)
            last_clk = peek_clock(mem2, clock, int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1_000_000))
            mem2.close()
        except OSError:
            pass

    ctx_vs_default = None
    if last_clk and last_clk.get("ctx"):
        ctx_vs_default = last_clk["ctx"] == hex(default_ctx)

    out = {
        "kind": "ppoll-timeout",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "clutter_base": hex(clutter_base),
        "glib_base": hex(glib_base),
        "default_ctx": hex(default_ctx),
        "clock": hex(clock) if clock else None,
        "last_clk": last_clk,
        "clock_ctx_is_default": ctx_vs_default,
        "kick_n": len(kick),
        "hz": round(len(kick) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        "sample_n": len(samples),
        "holes": holes,
    }
    Path("/tmp/dagu-ppoll-timeout.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-ppoll-timeout-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-ppoll-timeout-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-ppoll-timeout-{stamp}.json"
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-ppoll-timeout.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    # leave tracing on even if remote forgot
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
