#!/usr/bin/env python3
"""After flip+qcb with late nview: sample gnome-shell user PC/LR.

/proc/stat eip is useless while running. This SEIZEs the main thread
once, then PTRACE_INTERRUPT (~100us) to read user_pt_regs pc + x30.
KMS thread is not seized. At most 12 samples per hole, 3 holes.

When syscall=98, also record futex uaddr from /proc/pid/syscall.

No poke. From host: python3 linux-mainline/scripts/dagu-qcb-pc-probe.py --host
"""
from __future__ import annotations

import ctypes
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

PTRACE_CONT = 7
PTRACE_DETACH = 17
PTRACE_GETREGSET = 0x4204
PTRACE_SEIZE = 0x4206
PTRACE_INTERRUPT = 0x4207
NT_PRSTATUS = 1
WUNTRACED = 2


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


def walk_fp(pid, fp, maps, limit=12):
    out = []
    try:
        mem = open(f"/proc/{pid}/mem", "rb", buffering=0)
    except OSError:
        return out
    seen = set()
    try:
        for _ in range(limit):
            fp = fp & ((1 << 48) - 1)
            if fp < 0x10000 or fp in seen or (fp & 7):
                break
            seen.add(fp)
            try:
                mem.seek(fp)
                nxt, lr = struct.unpack("<QQ", mem.read(16))
            except (OSError, struct.error):
                break
            rec = {"fp": hex(fp), "lr": hex(lr), "sym": resolve(maps, lr)}
            out.append(rec)
            if nxt <= fp:
                break
            fp = nxt
    finally:
        mem.close()
    return out


def parse_ts(line):
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def parse_hex_field(line, key):
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0]
    try:
        return int(v, 16)
    except ValueError:
        return None


def read_sys(pid):
    try:
        raw = Path(f"/proc/{pid}/syscall").read_text().strip()
    except OSError:
        return "gone", None, []
    if raw == "running":
        return "running", None, []
    parts = raw.split()
    try:
        nr = parts[0]
        args = [int(x, 16) for x in parts[1:7]]
    except (ValueError, IndexError):
        return raw.split()[0] if raw else "gone", None, []
    return nr, args[0] if args else None, args


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
            err = ctypes.get_errno()
            raise OSError(err, f"PTRACE_SEIZE {err}")
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
                "sp": int(self.regs[31]),
                "fp": int(self.regs[29]),
                "x8": int(self.regs[8]),
            }
        finally:
            self.libc.ptrace(PTRACE_CONT, self.tid, None, None)

    def close(self):
        if not self.seized:
            return
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
    mf = map_rx(shell, "libmutter-18.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_qcb {mf}:0x1d6e40\n".encode())
        os.write(fd, f"p:dagu_nview {mf}:0x1c4440\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")
    return mf


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


def on_device(seconds=8.0):
    shell, lab = find_pids()
    maps = load_maps(shell)
    install(shell)
    tracer = Tracer(shell)
    seize_err = None
    try:
        tracer.seize()
    except OSError as e:
        seize_err = str(e)
    kick, flip, qcb, nview = [], [], [], []
    snaps = []
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    pending_q = None
    last_kick = None
    last_flip = None
    hole_snaps = 0
    holes_sampled = 0
    try:
        os.set_blocking(pipe.fileno(), False)
        buf = ""
        next_sample = 0.0
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
                        last_kick = ts
                    elif "dpu_crtc_complete_flip:" in line:
                        flip.append(ts)
                        last_flip = ts
                    elif "dagu_nview:" in line:
                        nview.append(ts)
                        pending_q = None
                        hole_snaps = 0
                    elif "dagu_qcb:" in line:
                        qcb.append(ts)
                        if (
                            last_flip is not None
                            and 0 <= (ts - last_flip) * 1000.0 <= 8
                            and (not nview or nview[-1] < last_flip - 0.001)
                            and holes_sampled < 3
                        ):
                            pending_q = ts
                            next_sample = now + 0.012
                            hole_snaps = 0
            if pending_q is not None and now >= next_sample and hole_snaps < 12:
                dt = (now - pending_q) * 1000.0
                if dt >= 12 and (not nview or nview[-1] < pending_q):
                    sysn, uaddr, args = read_sys(shell)
                    rec = {
                        "dt": round(dt, 2),
                        "sys": sysn,
                        "q_from_flip": round((pending_q - last_flip) * 1000.0, 2)
                        if last_flip else None,
                        "q_from_kick": round((pending_q - last_kick) * 1000.0, 2)
                        if last_kick else None,
                    }
                    if sysn == "98" and uaddr:
                        rec["futex"] = hex(uaddr)
                        rec["futex_where"] = resolve(maps, uaddr)
                    regs = tracer.sample() if tracer.seized else None
                    if regs and "pc" in regs:
                        rec["pc"] = hex(regs["pc"])
                        rec["lr"] = hex(regs["lr"])
                        rec["pc_sym"] = resolve(maps, regs["pc"])
                        rec["lr_sym"] = resolve(maps, regs["lr"])
                        rec["x8"] = regs.get("x8")
                        rec["bt"] = [
                            f.get("sym") for f in walk_fp(shell, regs.get("fp", 0), maps)
                            if f.get("sym")
                        ]
                    elif regs:
                        rec.update(regs)
                    snaps.append(rec)
                    hole_snaps += 1
                    next_sample = now + 0.004
                    if dt > 140:
                        pending_q = None
                        holes_sampled += 1
                elif nview and nview[-1] >= pending_q:
                    if hole_snaps:
                        holes_sampled += 1
                    pending_q = None
                    hole_snaps = 0
            if not chunk:
                time.sleep(0.0004)
    finally:
        pipe.close()
        tracer.close()
    (TR / "tracing_on").write_text("0\n")
    clear()
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        q = [round((x - a) * 1000.0, 2) for x in qcb if a - 0.004 <= x <= b + 0.002]
        n = [round((x - a) * 1000.0, 2) for x in nview if a - 0.004 <= x <= b + 0.002]
        f = [round((x - a) * 1000.0, 2) for x in flip if a - 0.008 <= x <= b + 0.002]
        early_q = [x for x in q if -2 <= x <= 15]
        early_n = [x for x in n if -2 <= x <= 15]
        late_n = [x for x in n if x >= 40]
        holes.append({
            "gap_ms": round(gap, 1),
            "flip": f[:4],
            "qcb": q[:6],
            "nview": n[:4],
            "kind": "nview-late" if late_n and not early_n and early_q else (
                "nview-ok" if early_n else "other"),
        })
    pcs = Counter(s.get("pc_sym") for s in snaps if s.get("pc_sym"))
    lrs = Counter(s.get("lr_sym") for s in snaps if s.get("lr_sym"))
    frames = Counter()
    for s in snaps:
        for f in s.get("bt") or []:
            frames[f] += 1
    out = {
        "kind": "qcb-pc",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "seize_err": seize_err,
        "kick": summary(kick),
        "n_qcb": len(qcb),
        "n_nview": len(nview),
        "n_snaps": len(snaps),
        "sys_snaps": dict(Counter(s.get("sys") for s in snaps)),
        "pc_top": dict(pcs.most_common(16)),
        "lr_top": dict(lrs.most_common(12)),
        "bt_top": dict(frames.most_common(20)),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:6],
        "snaps": snaps[:40],
    }
    Path("/tmp/dagu-qcb-pc.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-qcb-pc-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-qcb-pc-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-qcb-pc-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-qcb-pc.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
    return r.returncode


def main():
    args = [a for a in sys.argv[1:] if a != "--host"]
    seconds = 8.0
    if args:
        try:
            seconds = float(args[0])
        except ValueError:
            pass
    else:
        seconds = 12.0
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    return on_device(seconds)


if __name__ == "__main__":
    raise SystemExit(main())
