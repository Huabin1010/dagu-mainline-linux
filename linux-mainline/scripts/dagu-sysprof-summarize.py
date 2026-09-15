#!/usr/bin/env python3
"""Summarize sysprof-cat compositor marks. On tablet: python3 this.py /tmp/dagu-gs.syscap"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path


def parse(syscap: str) -> list[dict]:
    p = subprocess.run(
        ["sysprof-cat", "--no-callgraph", "--no-counters", "--no-metadata", syscap],
        capture_output=True,
        text=True,
    )
    text = p.stdout
    group = None
    in_mark = False
    rec: dict = {}
    marks: list[dict] = []
    for line in text.splitlines():
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
    syscap = sys.argv[1] if len(sys.argv) > 1 else "/tmp/dagu-gs.syscap"
    marks = parse(syscap)
    long8 = [m for m in marks if m.get("duration_ns", 0) >= 8_000_000]
    long50 = [m for m in marks if m.get("duration_ns", 0) >= 50_000_000]
    names = Counter((m.get("group"), m.get("name")) for m in marks)
    comp = [m for m in marks if m.get("group") in ("Compositor", "Compositor (KMS thread)")]
    durs = sorted(m.get("duration_ns", 0) for m in comp)
    pct = {}
    if durs:
        pct = {
            "n": len(comp),
            "p50_ms": round(durs[int((len(durs) - 1) * 0.5)] / 1e6, 3),
            "p99_ms": round(durs[int((len(durs) - 1) * 0.99)] / 1e6, 2),
            "max_ms": round(durs[-1] / 1e6, 2),
        }
    out = {
        "syscap": syscap,
        "n_marks": len(marks),
        "groups": dict(Counter(m.get("group") for m in marks)),
        "top_names": [(f"{a}|{b}", n) for (a, b), n in names.most_common(50)],
        "compositor_dur": pct,
        "n_ge8ms": len(long8),
        "n_ge50ms": len(long50),
        "long8_names": [
            (f"{a}|{b}", n)
            for (a, b), n in Counter(
                (m.get("group"), (m.get("name") or "")[:90]) for m in long8
            ).most_common(25)
        ],
        "long50": [
            {
                "ms": round(m["duration_ns"] / 1e6, 2),
                "group": m.get("group"),
                "name": m.get("name"),
                "message": m.get("message"),
                "end_s": round(m.get("end_ns", 0) / 1e9, 6),
                "start_s": round((m.get("end_ns", 0) - m.get("duration_ns", 0)) / 1e9, 6),
            }
            for m in sorted(long50, key=lambda x: -x["duration_ns"])[:25]
        ],
        "long8": [
            {
                "ms": round(m["duration_ns"] / 1e6, 2),
                "group": m.get("group"),
                "name": m.get("name"),
                "message": m.get("message"),
                "end_s": round(m.get("end_ns", 0) / 1e9, 6),
            }
            for m in sorted(long8, key=lambda x: -x["duration_ns"])[:30]
        ],
    }
    dest = Path("/tmp/dagu-sysprof-gs-summary.json")
    dest.write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    print(f"wrote {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
