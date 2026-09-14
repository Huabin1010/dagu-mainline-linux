#!/usr/bin/env python3
"""Correlate sysprof compositor marks with dpu_enc_kickoff holes."""
from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

HOLES = json.loads(Path("/tmp/dagu-sysprof-align.json").read_text())["kick"]["holes"]


def parse_marks(syscap: str) -> list[dict]:
    p = subprocess.run(
        ["sysprof-cat", "--no-callgraph", "--no-counters", "--no-metadata", syscap],
        capture_output=True,
        text=True,
    )
    group = None
    in_mark = False
    rec: dict = {}
    marks: list[dict] = []
    for line in p.stdout.splitlines():
        if re.search(r"^\s+group \{", line):
            group = None
            in_mark = False
            rec = {}
            continue
        if re.search(r"^\s+mark \{", line):
            in_mark = True
            rec = {"group": group}
            continue
        mm = re.search(r'name: "(.*)";', line)
        if mm and not in_mark:
            group = mm.group(1)
            continue
        if not in_mark:
            continue
        if mm:
            rec["name"] = mm.group(1)
            continue
        msg = re.search(r'message: "(.*)";', line)
        if msg:
            rec["message"] = msg.group(1)
            continue
        dur = re.search(r"duration: ([0-9]+);", line)
        if dur:
            rec["duration_ns"] = int(dur.group(1))
            continue
        et = re.search(r"end-time: ([0-9]+);", line)
        if et:
            rec["end_ns"] = int(et.group(1))
            continue
        if line.strip() == "}":
            if rec.get("name"):
                marks.append(rec)
            in_mark = False
            rec = {}
    return marks


def main() -> int:
    syscap = sys.argv[1] if len(sys.argv) > 1 else "/tmp/dagu-sysprof-align.syscap"
    marks = parse_marks(syscap)
    interesting = (
        "presented",
        "dispatch()",
        "maybe_post",
        "atomic_page_flip",
        "do_process",
        "swap_buffers",
        "egl_swap",
        "paint_view",
        "commit()",
    )
    per_name = Counter()
    hist = {}
    for m in marks:
        name = m.get("name") or ""
        if not any(s in name for s in interesting):
            continue
        durs = hist.setdefault(name[:70], [])
        durs.append(m.get("duration_ns", 0) / 1e6)
        per_name[name[:70]] += 1

    def stats(xs):
        xs = sorted(xs)
        if not xs:
            return {}
        return {
            "n": len(xs),
            "p50_ms": round(xs[int((len(xs) - 1) * 0.5)], 3),
            "p99_ms": round(xs[int((len(xs) - 1) * 0.99)], 2),
            "max_ms": round(xs[-1], 2),
            "n_ge8": sum(1 for x in xs if x >= 8),
            "n_ge50": sum(1 for x in xs if x >= 50),
        }

    name_stats = {k: stats(v) for k, v in hist.items()}

    hole_hits = []
    for h in HOLES:
        t0, t1 = h["t0"], h["t1"]
        overlap = []
        for m in marks:
            end = m.get("end_ns", 0) / 1e9
            start = end - m.get("duration_ns", 0) / 1e9
            if end < t0 - 0.002 or start > t1 + 0.002:
                continue
            ms = m.get("duration_ns", 0) / 1e6
            if ms < 2.0:
                continue
            overlap.append({
                "ms": round(ms, 2),
                "name": (m.get("name") or "")[:80],
                "group": m.get("group"),
                "message": (m.get("message") or "")[:120],
                "start_s": round(start, 6),
                "rel_start_ms": round((start - t0) * 1000, 2),
                "rel_end_ms": round((end - t0) * 1000, 2),
            })
        overlap.sort(key=lambda x: -x["ms"])
        hole_hits.append({
            **h,
            "n_marks_ge2ms": len(overlap),
            "top": overlap[:8],
        })

    out = {
        "name_stats": name_stats,
        "holes": hole_hits,
    }
    Path("/tmp/dagu-sysprof-align-holes.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
