#!/usr/bin/env python3
"""Sample kworker stacks on a real dpu_enc_kickoff hole.

Uses trace_pipe so events are not dropped by wiping `trace`.
"""
from __future__ import annotations

import json
import select
import threading
import time
from pathlib import Path

TR = Path("/sys/kernel/debug/tracing")
OUT = Path("/tmp/dagu-hole-kworker-stack.json")


def summarize(stack: str) -> list[str]:
    frames = []
    for line in stack.splitlines():
        s = line.strip()
        if not s:
            continue
        if "]" in s:
            s = s.split("]", 1)[-1].strip()
        frames.append(s.split("+", 1)[0])
    return frames[:14]


def drmish(frames: list[str]) -> bool:
    keys = ("drm_", "msm_", "dpu_", "commit_tail", "commit_work",
            "wait_for_completion", "wait_for_commit")
    return any(any(k in f for k in keys) for f in frames)


def snapshot() -> dict:
    kworkers = []
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            comm = (p / "comm").read_text().strip()
        except OSError:
            continue
        if not comm.startswith("kworker/u"):
            continue
        try:
            frames = summarize((p / "stack").read_text(errors="replace"))
        except OSError:
            continue
        if drmish(frames) or comm.startswith("kworker/u32"):
            kworkers.append({"pid": int(p.name), "comm": comm, "frames": frames,
                             "drm": drmish(frames)})
    shell = []
    gs = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            if (p / "cmdline").read_bytes().startswith(b"/usr/bin/gnome-shell"):
                gs = int(p.name)
                break
        except OSError:
            continue
    if gs:
        for tid_p in Path(f"/proc/{gs}/task").iterdir():
            if not tid_p.name.isdigit():
                continue
            try:
                comm = (tid_p / "comm").read_text().strip()
                frames = summarize(
                    Path(f"/proc/{gs}/task/{tid_p.name}/stack").read_text(
                        errors="replace"))
            except OSError:
                continue
            if comm in ("gnome-shell", "KMS thread") or drmish(frames):
                shell.append({"tid": int(tid_p.name), "comm": comm,
                              "frames": frames})
    return {
        "kworkers_drm": [k for k in kworkers if k["drm"]],
        "kworkers_u32": [{"comm": k["comm"], "drm": k["drm"],
                          "frames": k["frames"][:6]} for k in kworkers],
        "shell": shell,
    }


def main() -> int:
    (TR / "tracing_on").write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")

    last_kick = time.monotonic()
    n_kick = 0
    lock = threading.Lock()
    stop = False

    def reader() -> None:
        nonlocal last_kick, n_kick, stop
        with open(TR / "trace_pipe", "r", errors="replace") as fp:
            while not stop:
                r, _, _ = select.select([fp], [], [], 0.05)
                if not r:
                    continue
                line = fp.readline()
                if "dpu_enc_kickoff:" in line:
                    with lock:
                        n_kick += 1
                        last_kick = time.monotonic()

    th = threading.Thread(target=reader, daemon=True)
    th.start()
    time.sleep(0.3)

    captures = []
    in_hole = False
    t_end = time.monotonic() + 8.0
    while time.monotonic() < t_end:
        with lock:
            gap = time.monotonic() - last_kick
            nk = n_kick
        if gap >= 0.050 and not in_hole:
            in_hole = True
            snap = snapshot()
            snap["gap_ms"] = round(gap * 1000.0, 1)
            snap["n_kick"] = nk
            captures.append(snap)
        elif gap < 0.020:
            in_hole = False
        time.sleep(0.002)

    stop = True
    time.sleep(0.1)
    out = {"n_kick": n_kick, "n_captures": len(captures), "captures": captures}
    OUT.write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps({
        "n_kick": n_kick,
        "n_captures": len(captures),
        "preview": [
            {
                "gap_ms": c["gap_ms"],
                "drm": [{"comm": k["comm"], "top": k["frames"][:8]}
                        for k in c["kworkers_drm"]],
                "shell": [{"comm": s["comm"], "top": s["frames"][:6]}
                          for s in c["shell"]],
            }
            for c in captures
        ],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
