#!/usr/bin/env python3
"""Every nview-late hole: PC at +15/+45/+75 plus JS_GC/cycle in (-200, +280).

No poke. From host:
  python3 linux-mainline/scripts/dagu-nview-late-pc-probe.py --host
"""
from __future__ import annotations

import ctypes
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

PTRACE_CONT = 7
PTRACE_DETACH = 17
PTRACE_GETREGSET = 0x4204
PTRACE_SEIZE = 0x4206
PTRACE_INTERRUPT = 0x4207
NT_PRSTATUS = 1


class Iovec(ctypes.Structure):
    _fields_ = [("base", ctypes.c_void_p), ("len", ctypes.c_size_t)]


def ssh_base():
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def find_pids():
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
        raise SystemExit(json.dumps({"err": "need ubuntu+lab"}))
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


def load_maps(pid):
    out = []
    for line in open(f"/proc/{pid}/maps"):
        parts = line.split()
        lo, hi = (int(x, 16) for x in parts[0].split("-"))
        perm, off = parts[1], int(parts[2], 16)
        path = parts[-1] if len(parts) > 5 else ""
        out.append((lo, hi, off, perm, path))
    return out


def resolve(maps, pc):
    if not pc:
        return None
    pc = pc & ((1 << 48) - 1)
    for lo, hi, off, perm, path in maps:
        if lo <= pc < hi:
            name = path.rsplit("/", 1)[-1] if path.startswith("/") else (path or "anon")
            file_off = pc - lo + off if "x" in perm else pc - lo
            return f"{name}+{file_off:#x}"
    return hex(pc)


def drm_ioctl_name(req):
    if req is None:
        return None
    req = req & 0xFFFFFFFF
    nr = req & 0xFF
    names = {
        0xA3: "MODE_RMFB",
        0xA4: "MODE_PAGE_FLIP",
        0xA8: "MODE_DIRTYFB",
        0xB2: "MODE_CREATE_DUMB",
        0xB3: "MODE_MAP_DUMB",
        0xB4: "MODE_DESTROY_DUMB",
        0xB8: "MODE_ADDFB2",
        0xB9: "MODE_OBJ_GETPROPERTIES",
        0xBA: "MODE_OBJ_SETPROPERTY",
        0xBB: "MODE_CURSOR2",
        0xBC: "MODE_ATOMIC",
        0xBE: "SYNCOBJ_CREATE",
        0xBF: "SYNCOBJ_DESTROY",
        0xC0: "SYNCOBJ_HANDLE_TO_FD",
        0xC1: "SYNCOBJ_FD_TO_HANDLE",
        0xC2: "SYNCOBJ_WAIT",
        0xC3: "SYNCOBJ_RESET",
        0xC4: "SYNCOBJ_SIGNAL",
        0xC5: "MODE_CREATEPROPBLOB",
        0xC6: "MODE_DESTROYPROPBLOB",
        0xC7: "SYNCOBJ_TIMELINE_WAIT",
        0xC8: "SYNCOBJ_QUERY",
        0xC9: "SYNCOBJ_TRANSFER",
        0xCA: "SYNCOBJ_TIMELINE_SIGNAL",
    }
    return names.get(nr, f"nr={nr:#x}/{req:#x}")


def tag_pc(sym):
    if not sym:
        return "?"
    if "libmozjs" in sym:
        off = int(sym.split("+")[-1], 16)
        if 0x62C000 <= off <= 0x640000:
            return "mozjs-gc-blob"
        if 0x61C000 <= off <= 0x622000:
            return "mozjs-gc-barrier"
        return "mozjs-other"
    if "libgjs" in sym:
        return "gjs"
    if "libmutter" in sym:
        return "mutter"
    if "libglib" in sym:
        return "glib"
    if "libc.so" in sym:
        return "libc"
    return sym.split("+")[0]


def parse_ts(line):
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


class Tracer:
    def __init__(self, tid):
        self.tid = tid
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libc.ptrace.restype = ctypes.c_long
        self.libc.ptrace.argtypes = [
            ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p,
        ]
        self.regs = (ctypes.c_uint64 * 34)()
        self.iov = Iovec(ctypes.addressof(self.regs), ctypes.sizeof(self.regs))
        self.seized = False

    def seize(self):
        rc = self.libc.ptrace(PTRACE_SEIZE, self.tid, None, None)
        if rc != 0:
            raise OSError(ctypes.get_errno(), "PTRACE_SEIZE")
        self.seized = True

    def sample(self):
        if not self.seized:
            return None
        rc = self.libc.ptrace(PTRACE_INTERRUPT, self.tid, None, None)
        if rc != 0:
            return {"err": f"interrupt:{ctypes.get_errno()}"}
        try:
            _, status = os.waitpid(self.tid, 0)
            if not os.WIFSTOPPED(status):
                return {"err": f"wait:{status}"}
            rc = self.libc.ptrace(
                PTRACE_GETREGSET, self.tid,
                ctypes.c_void_p(NT_PRSTATUS),
                ctypes.byref(self.iov),
            )
            if rc != 0:
                return {"err": f"getreg:{ctypes.get_errno()}"}
            return {
                "pc": int(self.regs[32]),
                "lr": int(self.regs[30]),
                "x0": int(self.regs[0]),
                "x1": int(self.regs[1]),
                "x8": int(self.regs[8]),
            }
        finally:
            self.libc.ptrace(PTRACE_CONT, self.tid, None, None)

    def close(self):
        if self.seized:
            try:
                self.libc.ptrace(PTRACE_DETACH, self.tid, None, None)
            except OSError:
                pass
            self.seized = False


def install(shell):
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
    (TR / "buffer_size_kb").write_text("16384\n")
    mutter = map_rx(shell, "libmutter-18.so.0.0.0")
    mozjs = map_rx(shell, "libmozjs-140.so.140.8.0")
    gjs = map_rx(shell, "libgjs.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mutter}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifn {mutter}:0x1c4404\n".encode())
        os.write(fd, f"p:dagu_jsgc {mozjs}:0x44c6e0\n".encode())
        os.write(fd, f"p:dagu_cycle {mozjs}:0x62cee0\n".encode())
        os.write(fd, f"p:dagu_hammer {gjs}:0xa8624\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    p = TR / "events/dpu/dpu_crtc_complete_flip/enable"
    if p.is_file():
        p.write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


def summary(xs):
    gaps = [1000.0 * (b - a) for a, b in zip(xs, xs[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (xs[-1] - xs[0]) if len(xs) > 1 else 0
    return {
        "n": len(xs),
        "hz": round(len(xs) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
    }


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
    return None


def on_device(seconds=12.0):
    shell, lab = find_pids()
    maps = load_maps(shell)
    install(shell)
    tracer = Tracer(shell)
    seize_err = None
    try:
        tracer.seize()
    except OSError as e:
        seize_err = str(e)
    kick, flip, nview, ifn = [], [], [], []
    jsgc, cycle, hammer = [], [], []
    pending = None
    due = []
    snaps_by_kick = {}
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    try:
        os.set_blocking(pipe.fileno(), False)
        buf = ""
        while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
            now = time.clock_gettime(time.CLOCK_MONOTONIC)
            try:
                chunk = pipe.read(65536)
            except BlockingIOError:
                chunk = ""
            if chunk:
                buf += chunk
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    ts = parse_ts(line)
                    if ts is None:
                        continue
                    if "dpu_enc_kickoff:" in line:
                        kick.append(ts)
                    elif "dpu_crtc_complete_flip:" in line:
                        flip.append(ts)
                        if (not nview or nview[-1] < ts - 0.001):
                            pending = ts
                            due = [now + 0.008, now + 0.025, now + 0.050, now + 0.080]
                            snaps_by_kick.setdefault(ts, [])
                    elif "dagu_nview:" in line:
                        nview.append(ts)
                        pending = None
                        due = []
                    elif "dagu_ifn:" in line:
                        ifn.append(ts)
                    elif "dagu_jsgc:" in line:
                        jsgc.append(ts)
                    elif "dagu_cycle:" in line:
                        cycle.append(ts)
                    elif "dagu_hammer:" in line:
                        hammer.append(ts)
            if pending is not None and due and now >= due[0]:
                due.pop(0)
                if not nview or nview[-1] < pending:
                    regs = tracer.sample() if tracer.seized else None
                    rec = {"dt": round((now - pending) * 1000.0, 2)}
                    if regs and "pc" in regs:
                        rec["pc_sym"] = resolve(maps, regs["pc"])
                        rec["lr_sym"] = resolve(maps, regs["lr"])
                        rec["tag"] = tag_pc(rec["pc_sym"])
                        rec["x0"] = hex(regs.get("x0") or 0)
                        rec["x1"] = hex(regs.get("x1") or 0)
                        rec["x8"] = regs.get("x8")
                        if rec["tag"] == "libc" or (
                            rec.get("lr_sym") and "libdrm" in rec["lr_sym"]
                        ):
                            rec["ioctl"] = drm_ioctl_name(regs.get("x1"))
                    snaps_by_kick[pending].append(rec)
            if not chunk:
                time.sleep(0.0005)
    finally:
        pipe.close()
        tracer.close()
        clear()

    holes = []
    tags = Counter()
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n_early = first_after(nview, a, 0, 20)
        kind = "ifn-idle" if n_early is not None else "nview-late"
        fl = first_after(flip, a, 0, 20)
        rec = {
            "gap_ms": round(gap, 1),
            "kind": kind,
            "flip": fl,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 20),
            "jsgc": [
                round((x - a) * 1000.0, 2)
                for x in jsgc if -0.200 <= (x - a) <= 0.280
            ][:4],
            "cycle": [
                round((x - a) * 1000.0, 2)
                for x in cycle if -0.200 <= (x - a) <= 0.280
            ][:4],
            "hammer": [
                round((x - a) * 1000.0, 2)
                for x in hammer if -0.200 <= (x - a) <= 0.280
            ][:4],
            "snaps": [],
        }
        if fl is not None:
            ft = a + fl / 1000.0
            # nearest flip key
            best = None
            for k, snaps in snaps_by_kick.items():
                if abs(k - ft) < 0.004:
                    best = snaps
                    break
            rec["snaps"] = best or []
            for s in rec["snaps"]:
                tags[s.get("tag", "?")] += 1
        holes.append(rec)

    out = {
        "kind": "nview-late-pc",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "seize_err": seize_err,
        "kick": summary(kick),
        "n_jsgc": len(jsgc),
        "n_cycle": len(cycle),
        "n_hammer": len(hammer),
        "tag_counts": dict(tags),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-nview-late-pc.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main():
    extra = [a for a in sys.argv[1:] if a != "--host"]
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-nview-late-pc-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-nview-late-pc-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-nview-late-pc-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-nview-late-pc.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
    return r.returncode


def main():
    args = [a for a in sys.argv[1:] if a != "--host"]
    seconds = 12.0
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
