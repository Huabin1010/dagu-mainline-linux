#!/usr/bin/env python3
"""ifn-idle: is a DmaBuf GSource attached but not yet dispatched?

Never hook 0x1c4388 / 0x1c4404 / cave / 0x18ff40 / 0x84e0.
Hooks: nview 0x1c4440, hasnext 0x1c4398, attach 0x18fe78, dispatch 0x16e70c.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")


def ssh_base():
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


REMOTE = r'''
import json, time
from pathlib import Path

TR = Path("/sys/kernel/debug/tracing")
seconds = 10.0

def find_pids():
    shell = lab = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            c = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if c.startswith(b"/usr/bin/gnome-shell") and b"--mode=ubuntu" in c:
            shell = int(p.name)
        elif c.startswith(b"python") and b"dagu-native-lab.py" in c:
            lab = int(p.name)
    if shell is None or lab is None:
        raise SystemExit(json.dumps({"err": "need ubuntu+lab", "shell": shell, "lab": lab}))
    return shell, lab

def map_rx(pid, needle):
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

shell, lab = find_pids()
mu = map_rx(shell, "libmutter-18.so.0.0.0")
TR.joinpath("tracing_on").write_text("0\n")
ue = TR / "events/uprobes"
if ue.is_dir():
    (ue / "enable").write_text("0\n")
TR.joinpath("uprobe_events").write_text("")
with open("/sys/kernel/debug/tracing/uprobe_events", "w") as fd:
    fd.write(f"p:dagu_nview {mu}:0x1c4440\n")
    fd.write(f"p:dagu_hasnext {mu}:0x1c4398\n")
    fd.write(f"p:dagu_attach {mu}:0x18fe78\n")
    fd.write(f"p:dagu_disp {mu}:0x16e70c\n")
    fd.write(f"p:dagu_sendcb {mu}:0x1673f0\n")
for name in ("dagu_nview", "dagu_hasnext", "dagu_attach", "dagu_disp", "dagu_sendcb"):
    Path(f"/sys/kernel/debug/tracing/events/uprobes/{name}/enable").write_text("1\n")
TR.joinpath("events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
TR.joinpath("tracing_on").write_text("1\n")
TR.joinpath("trace").write_text("")
time.sleep(seconds)
raw = TR.joinpath("trace").read_text(errors="replace")
TR.joinpath("tracing_on").write_text("0\n")
if (TR / "events/uprobes").is_dir():
    (TR / "events/uprobes/enable").write_text("0\n")
TR.joinpath("uprobe_events").write_text("")
TR.joinpath("events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
TR.joinpath("events/dpu/dpu_crtc_vblank_cb/enable").write_text("1\n")
TR.joinpath("tracing_on").write_text("1\n")

def evs(needle):
    out = []
    for line in raw.splitlines():
        if needle not in line:
            continue
        for p in line.split():
            if p.endswith(":") and p[:-1].replace(".", "", 1).isdigit():
                out.append(float(p[:-1]))
                break
    return out

kicks = evs("dpu_enc_kickoff")
nview = evs("dagu_nview")
hasnext = evs("dagu_hasnext")
attach = evs("dagu_attach:")
disp = evs("dagu_disp:")
sendcb = evs("dagu_sendcb:")

def nearest(xs, t, lo, hi):
    hit = [x for x in xs if lo <= x - t <= hi]
    return hit[0] - t if hit else None

def last_before(xs, t):
    prev = [x for x in xs if x <= t]
    return (prev[-1] - t) if prev else None

def first_after(xs, t):
    nxt = [x for x in xs if x > t]
    return (nxt[0] - t) if nxt else None

gaps = [(a, b, 1000 * (b - a)) for a, b in zip(kicks, kicks[1:]) if b >= a]
holes = []
for a, b, gap in gaps:
    if gap <= 50:
        continue
    nv = nearest(nview, a, 0, gap / 1000.0 + 0.01)
    hn = nearest(hasnext, a, 0, 0.020)
    kind = "nview-late" if nv is None or nv > 20 else ("hasnext" if hn is not None else "ifn-idle")
    att_b = last_before(attach, a)
    disp_b = last_before(disp, a)
    att_a = first_after(attach, a)
    disp_a = first_after(disp, a)
    scb = first_after(sendcb, a)
    pending = None
    if att_b is not None and disp_b is not None:
        pending = att_b > disp_b  # attach more recent than dispatch
    elif att_b is not None and disp_b is None:
        pending = True
    elif att_b is None:
        pending = False
    holes.append({
        "gap_ms": round(gap, 1),
        "kind": kind,
        "nview": None if nv is None else round(nv, 2),
        "hasnext": None if hn is None else round(hn, 2),
        "att_before": None if att_b is None else round(1000 * att_b, 2),
        "disp_before": None if disp_b is None else round(1000 * disp_b, 2),
        "att_after": None if att_a is None else round(1000 * att_a, 2),
        "disp_after": None if disp_a is None else round(1000 * disp_a, 2),
        "sendcb_after": None if scb is None else round(1000 * scb, 2),
        "pending_at_kick": pending,
    })

span = kicks[-1] - kicks[0] if len(kicks) > 1 else 0
over = [g for *_, g in gaps if g > 50]
out = {
    "kind": "dmabuf-pending",
    "shell": shell,
    "lab": lab,
    "seconds": seconds,
    "kick": {
        "n": len(kicks),
        "hz": round(len(kicks) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
    },
    "n_nview": len(nview),
    "n_hasnext": len(hasnext),
    "n_attach": len(attach),
    "n_disp": len(disp),
    "n_sendcb": len(sendcb),
    "n_pending": sum(1 for h in holes if h["pending_at_kick"]),
    "n_nopend": sum(1 for h in holes if h["pending_at_kick"] is False),
    "holes": holes,
}
print(json.dumps(out, indent=2))
Path("/tmp/dagu-dmabuf-pending.json").write_text(json.dumps(out, indent=2) + "\n")
'''


def main():
    cmd = ssh_base() + ["python3", "-"]
    r = subprocess.run(cmd, input=REMOTE, text=True, capture_output=True)
    sys.stderr.write(r.stderr)
    if r.returncode != 0:
        sys.stderr.write(r.stdout)
        raise SystemExit(r.returncode)
    print(r.stdout)
    out_dir = ROOT / "out" / "display-stress"
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = out_dir / f"dagu-dmabuf-pending-{stamp}.json"
    # pull tablet copy if present
    subprocess.run(
        ssh_base()[:-1] + [
            "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            f"root@{HOST}:/tmp/dagu-dmabuf-pending.json", str(dest),
        ],
        check=False,
    )
    # local stdout already printed; also write if parseable
    try:
        dest.write_text(r.stdout if r.stdout.strip().startswith("{") else dest.read_text())
    except OSError:
        pass
    print("wrote", dest)


if __name__ == "__main__":
    main()
