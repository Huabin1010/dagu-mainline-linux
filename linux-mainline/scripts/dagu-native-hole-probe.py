#!/usr/bin/env python3
"""Align native-lab kickoff holes with Mutter clock + client wchan.

No poke. No Chrome. Same identity GTK page as dagu-native-lab.py.
On tablet: python3 /usr/local/sbin/dagu-native-hole-probe.py
From host: python3 linux-mainline/scripts/dagu-native-hole-probe.py --host
"""
from __future__ import annotations

import collections
import json
import os
import struct
import subprocess
import sys
import time
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")
DUMP = Path("/tmp/dagu-native-lab-dump.json")
CLOCK_HINT = 0x55A4B090D0
# This boot, gnome-shell 128256, verified rr=119.9998 / interval=8333.
CLOCK_LIVE = 0x55A5880720
STATE_NAMES = (
    "init", "idle", "scheduled", "scheduled-now", "scheduled-later",
    "dispatched-one", "dispatched-one-and-scheduled",
    "dispatched-one-and-scheduled-now", "dispatched-one-and-scheduled-later",
    "dispatched-two",
)


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


class Mem:
    def __init__(self, pid: int):
        self.f = open(f"/proc/{pid}/mem", "rb", buffering=0)

    def u64(self, a: int) -> int:
        self.f.seek(a)
        b = self.f.read(8)
        return struct.unpack("<Q", b)[0] if len(b) == 8 else 0

    def u32(self, a: int) -> int:
        self.f.seek(a)
        b = self.f.read(4)
        return struct.unpack("<I", b)[0] if len(b) == 4 else 0

    def f32(self, a: int) -> float:
        self.f.seek(a)
        b = self.f.read(4)
        return struct.unpack("<f", b)[0] if len(b) == 4 else 0.0


def find_pids() -> dict[str, int]:
    out: dict[str, int] = {}
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes().replace(b"\x00", b" ")
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell"):
            out["shell"] = int(p.name)
        elif b"dagu-native-lab.py" in cmd and b"--measure" not in cmd and b"--host" not in cmd:
            out["native"] = int(p.name)
        elif cmd.startswith(b"/usr/lib/chromium/chromium ") and b"--type=" not in cmd:
            out["chrome"] = int(p.name)
    return out


def maps(pid: int):
    rows = []
    for line in open(f"/proc/{pid}/maps"):
        parts = line.split()
        lo, hi = (int(x, 16) for x in parts[0].split("-"))
        perm, off = parts[1], int(parts[2], 16)
        path = parts[-1] if parts[-1].startswith("/") else ""
        rows.append((lo, hi, perm, off, path))
    return rows


def heap_ranges(pid: int):
    rs = []
    for lo, hi, perm, off, path in maps(pid):
        if "rw-p" not in perm:
            continue
        if path and path not in ("[heap]", "[anon:libc_malloc]") and not path.startswith("[anon"):
            continue
        sz = hi - lo
        if sz < 0x1000 or sz > 96 << 20:
            continue
        rs.append((lo, hi))
    return rs


def rx_clutter(pid: int) -> int:
    for lo, hi, perm, off, path in maps(pid):
        if "r-xp" in perm and off == 0 and "libmutter-clutter-18.so" in path:
            return lo
    return 0


def rx_mutter(pid: int) -> int:
    for lo, hi, perm, off, path in maps(pid):
        if "r-xp" in perm and off == 0 and "libmutter-18.so.0" in path:
            return lo
    return 0


def find_clock(sm: Mem, ranges) -> int:
    # Live so: refresh_rate +28 (float, often 119.9998 not 120.0),
    # refresh_interval_us +32 == 8333, state +88, mode +92, inhibit +404.
    pat = struct.pack("<q", 8333)
    for lo, hi in ranges:
        try:
            sm.f.seek(lo)
            blob = sm.f.read(min(hi - lo, 16 << 20))
        except OSError:
            continue
        idx = 0
        while True:
            i = blob.find(pat, idx)
            if i < 0:
                break
            if i >= 32 and ((lo + i - 32) & 7) == 0:
                rr = struct.unpack_from("<f", blob, i - 4)[0]
                st = struct.unpack_from("<I", blob, i + 56)[0] if i + 60 <= len(blob) else 99
                mode = struct.unpack_from("<I", blob, i + 60)[0] if i + 64 <= len(blob) else 99
                if 100.0 <= rr <= 130.0 and st <= 12 and mode <= 3:
                    return lo + i - 32
            idx = i + 1
    return 0


def wchan(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/wchan").read_text().strip()[:48]
    except OSError:
        return "?"


def syscall_of(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/syscall").read_text().strip().split()[0]
    except OSError:
        return "?"


def load_dump() -> dict:
    if not DUMP.is_file():
        return {}
    try:
        return json.loads(DUMP.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def read_int(path: str) -> int | None:
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return None


def drm_planes() -> dict:
    p = Path("/sys/kernel/debug/dri/0/state")
    if not p.is_file():
        return {}
    planes = []
    cur = {}
    for line in p.read_text(errors="replace").splitlines():
        if line.startswith("plane["):
            if cur:
                planes.append(cur)
            cur = {"name": line.strip()}
        elif cur and line.startswith("\t") and (
            "fb=" in line or "format=" in line or "crtc-pos=" in line
            or "modifier=" in line or "crtc=" in line
        ):
            cur[line.strip().split("=")[0]] = line.strip()
    if cur:
        planes.append(cur)
    return {"n": len(planes), "planes": planes[:4]}


def parse_trace(raw: str) -> dict:
    kick, vblank, flip = [], [], []
    for line in raw.splitlines():
        if line[:1] == "#":
            continue
        ev = None
        if "dpu_enc_kickoff:" in line:
            ev = "kick"
        elif "dpu_crtc_vblank_cb:" in line:
            ev = "vblank"
        elif "dpu_crtc_complete_flip:" in line:
            ev = "flip"
        if not ev:
            continue
        for tok in line.split():
            if tok.endswith(":") and tok[:-1].replace(".", "", 1).isdigit():
                ts = float(tok[:-1])
                if ev == "kick":
                    kick.append(ts)
                elif ev == "vblank":
                    vblank.append(ts)
                else:
                    flip.append(ts)
                break
    return {"kick": kick, "vblank": vblank, "flip": flip}


def gap_sum(ts: list[float]) -> dict:
    gaps = [1000.0 * (b - a) for a, b in zip(ts, ts[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (ts[-1] - ts[0]) if len(ts) > 1 else 0
    return {
        "n": len(ts),
        "hz": round(len(ts) / span, 2) if span > 0 else 0,
        "p50": round(sorted(gaps)[len(gaps) // 2], 2) if gaps else None,
        "max": round(max(gaps), 1) if gaps else None,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:10]],
        "span": round(span, 3),
    }


def on_device(seconds: float = 8.0) -> int:
    pids = find_pids()
    if "shell" not in pids or "native" not in pids:
        print(json.dumps({"err": "need gnome-shell + native-lab", "pids": pids}))
        return 2
    if "chrome" in pids:
        print(json.dumps({"err": "chrome still running", "pids": pids}))
        return 2
    sm = Mem(pids["shell"])
    clock = 0
    for cand in (CLOCK_LIVE, CLOCK_HINT):
        try:
            rr = sm.f32(cand + 28)
            iv = sm.u32(cand + 32)
            st = sm.u32(cand + 88)
            if 100.0 <= rr <= 130.0 and 7000 <= iv <= 10000 and st <= 12:
                clock = cand
                break
        except OSError:
            continue
    if not clock:
        clock = find_clock(sm, heap_ranges(pids["shell"]))
    clock_meta = {}
    if clock:
        try:
            clock_meta = {
                "rr": sm.f32(clock + 28),
                "interval_us": sm.u32(clock + 32),
                "st0": sm.u32(clock + 88),
                "mode0": sm.u32(clock + 92),
            }
        except OSError:
            clock_meta = {}
    clutter_rx = rx_clutter(pids["shell"])
    mutter_rx = rx_mutter(pids["shell"])
    insn = None
    if clutter_rx:
        try:
            insn = hex(sm.u32(clutter_rx + 0x67C00))
        except OSError:
            insn = None

    (TR / "tracing_on").write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("8192\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_vblank_cb/enable").write_text("1\n")
    flip_ev = TR / "events/dpu/dpu_crtc_complete_flip/enable"
    if flip_ev.parent.is_dir():
        flip_ev.write_text("1\n")
    (TR / "tracing_on").write_text("1\n")

    samples = []
    hist = collections.Counter()
    t0 = time.monotonic()
    while time.monotonic() - t0 < seconds:
        st = pr = inh = mode = -1
        if clock:
            try:
                st = sm.u32(clock + 88)
                mode = sm.u32(clock + 92)
                pr = sm.u32(clock + 396)
                inh = sm.u32(clock + 404)
            except OSError:
                clock = 0
        row = {
            "t": time.monotonic(),
            "st": st,
            "mode": mode,
            "pr": pr,
            "inh": inh,
            "wchan_shell": wchan(pids["shell"]),
            "wchan_native": wchan(pids["native"]),
            "sys_native": syscall_of(pids["native"]),
            "gpu_busy": read_int("/sys/class/drm/card0/device/gpu_busy_percent"),
        }
        samples.append(row)
        hist[(STATE_NAMES[st] if 0 <= st < len(STATE_NAMES) else str(st), pr, inh)] += 1
        time.sleep(0.004)

    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    tr = parse_trace(raw)
    kick, vblank, flip = tr["kick"], tr["vblank"], tr["flip"]
    holes = []
    if samples and kick:
        s0, s1 = samples[0]["t"], samples[-1]["t"]
        k0, k1 = kick[0], kick[-1]
        span_s = max(s1 - s0, 1e-6)
        span_k = max(k1 - k0, 1e-6)
        for a, b in zip(kick, kick[1:]):
            gap = (b - a) * 1000.0
            if gap <= 50:
                continue
            rel0 = (a - k0) / span_k
            rel1 = (b - k0) / span_k
            lo = s0 + rel0 * span_s
            hi = s0 + rel1 * span_s
            near = [s for s in samples if lo - 0.01 <= s["t"] <= hi + 0.01]
            st_c = collections.Counter(
                STATE_NAMES[s["st"]] if 0 <= s["st"] < len(STATE_NAMES) else str(s["st"])
                for s in near
            )
            holes.append({
                "gap_ms": round(gap, 1),
                "vblank_n": sum(1 for t in vblank if a <= t <= b),
                "flip_n": sum(1 for t in flip if a < t <= b),
                "clock": dict(st_c),
                "pr": dict(collections.Counter(s["pr"] for s in near)),
                "wchan_shell": dict(collections.Counter(s["wchan_shell"] for s in near)),
                "wchan_native": dict(collections.Counter(s["wchan_native"] for s in near)),
                "sys_native": dict(collections.Counter(s["sys_native"] for s in near)),
                "gpu_busy": [s["gpu_busy"] for s in near],
                "kernel_verdict": (
                    "userspace-no-commit"
                    if sum(1 for t in vblank if a <= t <= b) >= 4
                    and sum(1 for t in flip if a < t <= b) <= 1
                    else "short-or-mixed"
                ),
            })

    out = {
        "kind": "native-hole-probe",
        "seconds": seconds,
        "pids": pids,
        "clock": hex(clock) if clock else None,
        "clock_meta": clock_meta,
        "clutter_rx": hex(clutter_rx) if clutter_rx else None,
        "mutter_rx": hex(mutter_rx) if mutter_rx else None,
        "maybe_reschedule_insn": insn,
        "dump": load_dump(),
        "drm": drm_planes(),
        "kickoff": gap_sum(kick),
        "vblank": gap_sum(vblank),
        "flip": gap_sum(flip),
        "clock_hist": [[list(k), n] for k, n in hist.most_common(12)],
        "holes": holes,
        "samples_n": len(samples),
    }
    Path("/tmp/dagu-native-hole-probe.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main() -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-native-hole-probe.py"], check=True)
    subprocess.run(ssh + [
        "install -m755 /tmp/dagu-native-hole-probe.py /usr/local/sbin/dagu-native-hole-probe.py"
    ], check=True)
    r = subprocess.run(
        ssh + ["python3 /usr/local/sbin/dagu-native-hole-probe.py"],
        check=False,
    )
    out_host = ROOT / "out" / "display-stress"
    out_host.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = out_host / f"dagu-native-hole-probe-{stamp}.json"
    subprocess.run(
        scp + [f"root@{HOST}:/tmp/dagu-native-hole-probe.json", str(dest)],
        check=False,
    )
    if dest.is_file():
        print(dest.read_text())
    return r.returncode


def main() -> int:
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    return on_device()


if __name__ == "__main__":
    raise SystemExit(main())
