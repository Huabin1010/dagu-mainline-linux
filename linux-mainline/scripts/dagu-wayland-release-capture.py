#!/usr/bin/env python3
"""Align WAYLAND_DEBUG=1 Chrome stderr with dpu_enc_kickoff holes.

No /proc/mem poke. Answers one question: does wl_buffer@N.release
appear on the client wire during a kickoff gap >50ms?

Runs on the tablet as root. Restart identity with DAGU_WAYLAND_DEBUG=1
first (or pass --spawn).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time
import urllib.request
from pathlib import Path

TR = Path("/sys/kernel/debug/tracing")
CHROME_LOG = Path("/tmp/dagu-lab-identity.chrome.log")
OUT_DIR = Path("/tmp/dagu-wayland-release-cap")

# official-152 Ozone: [3192062.157] discarded wl_buffer#78.release()
# libwayland-style:    [  1234.567]  -> wl_buffer@60.release()
RE_WD = re.compile(
    r"^\[\s*(?P<sec>\d+)\.(?P<frac>\d+)\]\s*(?P<arrow>->\s*)?(?P<rest>.*)$"
)
RE_BUF_REL = re.compile(r"wl_buffer[#@](\d+)\.release\b")
RE_DISC_REL = re.compile(r"discarded wl_buffer[#@](\d+)\.release\b")
RE_BUF_ANY = re.compile(r"wl_buffer[#@](\d+)\.")
RE_ATTACH = re.compile(r"wl_surface[#@](\d+)\.attach\(.*wl_buffer[#@](\d+)")
RE_COMMIT = re.compile(r"wl_surface[#@](\d+)\.commit\(")
RE_PRES = re.compile(r"wp_presentation_feedback[#@](\d+)\.presented\b")
RE_SYNCOBJ = re.compile(r"linux_drm_syncobj|wp_linux_drm_syncobj")


def dump_lab():
    d = json.loads(urllib.request.urlopen("http://127.0.0.1:8770/api/dump", timeout=3).read())
    h = d.get("host") or d.get("hw") or {}
    v = d.get("verdict") or {}
    return {
        "fps": d.get("fps"),
        "p50": d.get("p50"),
        "p99": d.get("p99"),
        "max": d.get("max"),
        "holes": d.get("holes"),
        "video14_open": h.get("video14_open"),
        "software_decode": v.get("software_decode"),
        "vblank_fps": h.get("vblank_fps"),
        "venus_irq": h.get("venus_irq"),
    }


def wait_identity(timeout=45.0):
    t0 = time.monotonic()
    last = None
    while time.monotonic() - t0 < timeout:
        try:
            last = dump_lab()
        except Exception as e:
            last = {"err": str(e)}
            time.sleep(1.0)
            continue
        if (
            last.get("p50") in (8.3, 8.4, 8.5)
            and last.get("video14_open") == 2
            and last.get("software_decode") is False
        ):
            return last
        time.sleep(1.0)
    return last


def spawn_identity():
    env = os.environ.copy()
    env["DAGU_WAYLAND_DEBUG"] = "1"
    subprocess.check_call(["/usr/local/sbin/dagu-lab-identity-120.sh"], env=env)


def arm_trace():
    (TR / "tracing_on").write_text("0\n")
    try:
        (TR / "trace_clock").write_text("mono\n")
    except OSError:
        pass
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("16384\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")


def read_kickoff_ts():
    (TR / "tracing_on").write_text("0\n")
    ts = []
    raw = (TR / "trace").read_text(errors="replace")
    for line in raw.splitlines():
        if "dpu_enc_kickoff" not in line or line[:1] == "#":
            continue
        parts = line.split()
        for p in parts:
            if p.endswith(":") and p[:-1].replace(".", "", 1).isdigit():
                try:
                    ts.append(float(p[:-1]))
                    break
                except ValueError:
                    pass
    return ts, raw


def parse_wayland(path: Path):
    rows = []
    with path.open("r", errors="replace") as f:
        for line in f:
            m = RE_WD.match(line.rstrip("\n"))
            if not m:
                continue
            sec = int(m.group("sec"))
            frac = m.group("frac")
            # libwayland: tv_sec + tv_nsec/1e6 → milliseconds in frac (3 digits)
            if len(frac) <= 3:
                t = sec + int(frac) / (10 ** len(frac))
            else:
                t = sec + int(frac) / (10 ** len(frac))
            incoming = bool(m.group("arrow"))
            rest = m.group("rest")
            rows.append(
                {
                    "t": t,
                    "in": incoming,
                    "line": rest,
                    "raw": line.rstrip("\n")[:240],
                }
            )
    return rows


def holes_from_kickoff(ts, min_gap_ms=50.0):
    holes = []
    for a, b in zip(ts, ts[1:]):
        if b < a:
            continue
        gap = 1000.0 * (b - a)
        if gap > min_gap_ms:
            holes.append({"t0": a, "t1": b, "gap_ms": round(gap, 2)})
    return holes


def events_in(rows, t0, t1):
    return [r for r in rows if t0 <= r["t"] <= t1]


def summarize_window(rows):
    rel = []
    attach = []
    commit = []
    syncobj = 0
    presented = 0
    ids = set()
    for r in rows:
        line = r["line"]
        m = RE_BUF_REL.search(line)
        if m:
            rel.append({"id": int(m.group(1)), "in": r["in"], "t": r["t"], "raw": r["raw"]})
            ids.add(int(m.group(1)))
        ma = RE_ATTACH.search(line)
        if ma:
            attach.append({"surf": int(ma.group(1)), "buf": int(ma.group(2)), "in": r["in"]})
        if RE_COMMIT.search(line):
            commit.append(r["t"])
        if RE_SYNCOBJ.search(line):
            syncobj += 1
        if "presented" in line:
            presented += 1
        for b in RE_BUF_ANY.findall(line):
            ids.add(int(b))
    return {
        "n": len(rows),
        "incoming": sum(1 for r in rows if r["in"]),
        "outgoing": sum(1 for r in rows if not r["in"]),
        "release": rel,
        "release_n": len(rel),
        "attach_n": len(attach),
        "commit_n": len(commit),
        "syncobj_n": syncobj,
        "presented_n": presented,
        "buffer_ids": sorted(ids),
        "head": [r["raw"] for r in rows[:8]],
        "release_lines": [x["raw"] for x in rel[:12]],
    }


def detect_clock(rows, real0, mono0):
    """Guess whether WAYLAND_DEBUG timestamps are realtime or monotonic."""
    if not rows:
        return {"kind": "empty"}
    t = rows[len(rows) // 2]["t"]
    # epoch-like
    if t > 1e9:
        return {"kind": "realtime_epoch", "sample": t}
    # monotonic-ish seconds since boot (uptime)
    if 10 < t < 1e7:
        return {"kind": "monotonic_or_uptime", "sample": t}
    return {"kind": "unknown", "sample": t}


def to_mono(t, kind, real0, mono0, wd_t0, cap_mono0):
    if kind == "realtime_epoch":
        return t - real0 + mono0
    if kind == "monotonic_or_uptime":
        # treat as same domain as ftrace mono if close to cap_mono0
        if abs(t - cap_mono0) < 3600:
            return t
        # else offset by first wayland line vs capture start
        return t - wd_t0 + cap_mono0
    return t - wd_t0 + cap_mono0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spawn", action="store_true", help="restart identity with WAYLAND_DEBUG=1")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--no-restore", action="store_true")
    args = ap.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if args.spawn:
        if CHROME_LOG.exists():
            CHROME_LOG.write_text("")
        spawn_identity()
        ident = wait_identity()
    else:
        ident = wait_identity(timeout=8.0)

    log_pos = CHROME_LOG.stat().st_size if CHROME_LOG.exists() else 0
    real0 = time.time()
    mono0 = time.clock_gettime(time.CLOCK_MONOTONIC)
    arm_trace()
    cap_mono0 = time.clock_gettime(time.CLOCK_MONOTONIC)
    time.sleep(args.seconds)
    cap_mono1 = time.clock_gettime(time.CLOCK_MONOTONIC)
    real1 = time.time()
    kick_ts, kick_raw = read_kickoff_ts()
    lab1 = dump_lab()

    slice_path = OUT_DIR / "wayland-slice.log"
    with CHROME_LOG.open("rb") as f:
        f.seek(log_pos)
        chunk = f.read()
    slice_path.write_bytes(chunk)
    (OUT_DIR / "kickoff.trace").write_text(kick_raw)

    rows = parse_wayland(slice_path)
    clock = detect_clock(rows, real0, mono0)
    wd_t0 = rows[0]["t"] if rows else 0.0
    kind = clock["kind"]
    for r in rows:
        r["mono"] = to_mono(r["t"], kind, real0, mono0, wd_t0, cap_mono0)

    holes = holes_from_kickoff(kick_ts)
    hole_reports = []
    for h in holes:
        # ftrace mono timestamps are seconds since boot; cap window is cap_mono0..cap_mono1
        win0, win1 = h["t0"], h["t1"]
        # pad 2ms before, 8ms after (release may land at hole end)
        ev = [r for r in rows if (win0 - 0.002) <= r["mono"] <= (win1 + 0.008)]
        sm = summarize_window(ev)
        sm["hole"] = h
        sm["has_release"] = sm["release_n"] > 0
        hole_reports.append(sm)

    all_rel = [r for r in rows if RE_BUF_REL.search(r["line"])]
    rel_ids = sorted({int(RE_BUF_REL.search(r["line"]).group(1)) for r in all_rel})

    gaps = [1000.0 * (b - a) for a, b in zip(kick_ts, kick_ts[1:]) if b >= a]
    span = (kick_ts[-1] - kick_ts[0]) if len(kick_ts) > 1 else 0
    out = {
        "ident_before": ident,
        "lab_after": lab1,
        "clock": clock,
        "sync": {
            "real0": real0,
            "real1": real1,
            "mono0": mono0,
            "cap_mono0": cap_mono0,
            "cap_mono1": cap_mono1,
        },
        "wayland": {
            "bytes": len(chunk),
            "lines_parsed": len(rows),
            "incoming": sum(1 for r in rows if r["in"]),
            "outgoing": sum(1 for r in rows if not r["in"]),
            "release_n": len(all_rel),
            "release_ids": rel_ids,
            "release_incoming": sum(1 for r in all_rel if r["in"]),
            "release_outgoing": sum(1 for r in all_rel if not r["in"]),
            "first": rows[0]["raw"] if rows else None,
            "sample_release": [r["raw"] for r in all_rel[:8]],
        },
        "kickoff": {
            "n": len(kick_ts),
            "hz": round(len(kick_ts) / span, 2) if span else 0,
            "max": round(max(gaps), 1) if gaps else None,
            "gt50": len(holes),
            "gt50_ms": [h["gap_ms"] for h in holes[:12]],
            "span": round(span, 3),
        },
        "holes": hole_reports,
        "verdict": {
            "holes": len(holes),
            "holes_with_release": sum(1 for h in hole_reports if h["has_release"]),
            "holes_without_release": sum(1 for h in hole_reports if not h["has_release"]),
        },
    }
    (OUT_DIR / "report.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))

    if args.spawn and not args.no_restore:
        # leave lab usable without flooding stderr
        subprocess.check_call(["/usr/local/sbin/dagu-lab-identity-120.sh"])


if __name__ == "__main__":
    main()
