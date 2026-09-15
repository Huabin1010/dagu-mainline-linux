#!/usr/bin/env python3
"""B-main / B-kick 8s window against identity GTK native lab.

Uprobes MUST hit the live mapping (deleted inode). Use map_files.
From host: python3 linux-mainline/scripts/dagu-bmain-probe.py --host
"""
from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import threading
import time
from collections import Counter
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")

PROBES = {
    "dagu_impl": "0x1bd2c0",   # flipped_in_impl
    "dagu_nview": "0x1c4440",  # notify_view_crtc_presented
    "dagu_ifgl": "0x1c4380",  # maybe_post_if_gl_finished
    "dagu_mpent": "0x1c1b20", # maybe_post entry
    "dagu_mgo": "0x1c1c04",    # maybe_post real post (after posted==NULL)
    "dagu_qcb": "0x1d6e40",    # meta_thread_queue_callback
    "dagu_disp": "0x1d5d00",   # callback_source_dispatch
    "dagu_inv": "0x1b9548",    # invoke_page_flip_closure_flipped
    "dagu_atomic": "0x1b4878", # drmModeAtomicCommit (page-flip)
    "dagu_atmerr": "0x1b434c", # atomic ret<0
    "dagu_ready": "0x1bd740",  # update_ready
    "dagu_emit": "0x167340",   # emit_frame_callbacks_for_stage_view
    "dagu_sendcb": "0x1673f0", # wl_callback_send_done (real client wake)
    "dagu_apply": "0x165124",  # meta_wayland_actor_surface_apply_state
}

# libmutter-clutter-18.so (frame clock lives here, not libmutter-18)
CLUTTER_PROBES = {
    "dagu_npresent": "0x67cc4",  # clutter_frame_clock_notify_presented
    "dagu_sched": "0x675a0",     # clutter_frame_clock_schedule_update
    "dagu_schednow": "0x6732c",  # clutter_frame_clock_schedule_update_now
    "dagu_fcdisp": "0x73c0c",    # clutter_frame_clock_dispatch
    "dagu_stsked": "0x9db50",    # clutter_stage_schedule_update
    "dagu_stgo": "0x9db94",      # passed update_scheduled / event_queue early-out
}

# fetch x1=next_update_time_us at the store before set_ready_time
CLUTTER_FETCH = {
    "dagu_rdyt": ("0x67714", "x1=%x1 x5=%x5"),
}

# lab process libgtk-4
GTK_PROBES = {
    "dagu_reqph": "0x5733d0",  # gdk_frame_clock_request_phase
}


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


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
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
    }


def first_after(ts: list[float], t0: float, t1: float) -> float | None:
    for t in ts:
        if t0 <= t <= t1:
            return t
    return None


def parse_trace(raw: str) -> dict:
    kick, flip = [], []
    ev = {k: [] for k in list(PROBES) + list(CLUTTER_PROBES) +
          list(CLUTTER_FETCH) + list(GTK_PROBES)}
    ev["rdyt"] = []  # (ts, ready_us, clock_ptr)
    ev["kick"] = kick
    ev["flip"] = flip
    ev["wstart"] = []
    ev["wfinish"] = []
    ev["wcommit"] = []
    ev["wdone"] = []
    ev["tail_s"] = []
    ev["tail_f"] = []
    ev["flush"] = []
    ev["ctail"] = []
    ev["wdep"] = []
    ev["wfence"] = []
    ev["src_ptr"] = []
    for line in raw.splitlines():
        if line[:1] == "#":
            continue
        ts = None
        for tok in line.split():
            if tok.endswith(":") and tok[:-1].replace(".", "", 1).isdigit():
                ts = float(tok[:-1])
                break
        if ts is None:
            continue
        if "dpu_enc_kickoff:" in line:
            kick.append(ts)
        elif "dpu_crtc_complete_flip:" in line:
            flip.append(ts)
        elif "msm_atomic_wait_flush_start:" in line:
            ev["wstart"].append(ts)
        elif "msm_atomic_wait_flush_finish:" in line:
            ev["wfinish"].append(ts)
        elif "dpu_kms_wait_for_commit_done:" in line:
            ev["wcommit"].append(ts)
        elif "dpu_enc_wait_event_timeout:" in line:
            ev["wdone"].append(ts)
        elif "msm_atomic_commit_tail_start:" in line:
            ev["tail_s"].append(ts)
        elif "msm_atomic_commit_tail_finish:" in line:
            ev["tail_f"].append(ts)
        elif "msm_atomic_flush_commit:" in line:
            ev["flush"].append(ts)
        elif "dagu_ctail:" in line:
            ev["ctail"].append(ts)
        elif "dagu_wdep:" in line:
            ev["wdep"].append(ts)
        elif "dagu_wfence:" in line:
            ev["wfence"].append(ts)
        elif "dagu_src:" in line:
            ev.setdefault("src_ts", []).append(ts)
            for tok in line.replace(")", " ").replace("(", " ").split():
                if tok.startswith("x19=") or (tok.startswith("0x") and len(tok) >= 10):
                    try:
                        ev["src_ptr"].append(int(tok.split("=")[-1], 16))
                    except ValueError:
                        pass
        for name in list(PROBES) + list(CLUTTER_PROBES) + list(CLUTTER_FETCH) + list(GTK_PROBES):
            if f"{name}:" in line:
                ev[name].append(ts)
        if "dagu_rdyt:" in line:
            x1 = x5 = None
            for tok in line.replace(")", " ").replace("(", " ").split():
                if tok.startswith("x1="):
                    try:
                        x1 = int(tok.split("=", 1)[1], 16)
                    except ValueError:
                        pass
                elif tok.startswith("x5="):
                    try:
                        x5 = int(tok.split("=", 1)[1], 16)
                    except ValueError:
                        pass
            ev["rdyt"].append((ts, x1, x5))
    return ev


def gnome_and_lab() -> tuple[int, int, str, int]:
    pid = native = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell"):
            pid = int(p.name)
        elif (b"dagu-native-lab.py" in cmd and b"--host" not in cmd
              and b"sudo" not in cmd.split(b"\x00", 1)[0]
              and cmd.startswith(b"python")):
            native = int(p.name)
    if pid is None or native is None:
        raise SystemExit(json.dumps({"err": "need gnome-shell + native-lab",
                                     "pid": pid, "native": native}))
    mf = None
    base = None
    for line in open(f"/proc/{pid}/maps"):
        if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
            rng = line.split()[0]
            base = int(rng.split("-", 1)[0], 16)
            mf = f"/proc/{pid}/map_files/{rng}"
            break
    if not mf or not Path(mf).exists():
        raise SystemExit("no live libmutter-18 r-xp")
    cmf = cbase = None
    for line in open(f"/proc/{pid}/maps"):
        if "libmutter-clutter-18.so" in line and "r-xp" in line:
            rng = line.split()[0]
            cbase = int(rng.split("-", 1)[0], 16)
            cmf = f"/proc/{pid}/map_files/{rng}"
            break
    if not cmf or not Path(cmf).exists():
        raise SystemExit("no live libmutter-clutter-18 r-xp")
    gmf = gbase = None
    for line in open(f"/proc/{native}/maps"):
        if "libgtk-4.so" in line and "r-xp" in line:
            rng = line.split()[0]
            gbase = int(rng.split("-", 1)[0], 16)
            gmf = f"/proc/{native}/map_files/{rng}"
            break
    return pid, native, mf, base, cmf, cbase, gmf, gbase


def on_device(seconds: float = 8.0, tag: str = "") -> int:
    pid, native, mf, base, cmf, cbase, gmf, gbase = gnome_and_lab()
    mem = open(f"/proc/{pid}/mem", "rb", buffering=0)

    def u32(off: int) -> int:
        mem.seek(base + off)
        return struct.unpack("<I", mem.read(4))[0]

    insn = {
        "1bd9ac": hex(u32(0x1bd9ac)),
        "1bd9d8": hex(u32(0x1bd9d8)),
        "1bd7d4": hex(u32(0x1bd7d4)),
        "1d6ee4": hex(u32(0x1d6ee4)),
        "1d6f10": hex(u32(0x1d6f10)),
        "1d6e94": hex(u32(0x1d6e94)),
        "1b4820": hex(u32(0x1b4820)),
    }
    mem.close()
    mesa_base = None
    for line in open(f"/proc/{pid}/maps"):
        if "libgallium-26.0.8" in line and "r-xp" in line:
            mesa_base = int(line.split("-", 1)[0], 16)
            break
    if mesa_base is not None:
        mem = open(f"/proc/{pid}/mem", "rb", buffering=0)
        mem.seek(mesa_base + 0x1cf740)
        insn["mesa_1cf740"] = hex(struct.unpack("<I", mem.read(4))[0])
        mem.seek(mesa_base + 0x1cf74c)
        insn["mesa_1cf74c"] = hex(struct.unpack("<I", mem.read(4))[0])
        mem.close()

    (TR / "tracing_on").write_text("0\n")
    en0 = TR / "events/uprobes/enable"
    if en0.is_file():
        en0.write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("16384\n")
    ue = TR / "uprobe_events"
    # truncate clears; "a" text writes can EINVAL on this kernel
    # enable=0 first or this returns EBUSY
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
        for name, off in PROBES.items():
            line = f"p:{name} {mf}:{off}\n".encode()
            try:
                os.write(fd, line)
                installed.append(name)
            except OSError as e:
                installed.append(f"{name}:FAIL:{e}")
        for name, off in CLUTTER_PROBES.items():
            line = f"p:{name} {cmf}:{off}\n".encode()
            try:
                os.write(fd, line)
                installed.append(name)
            except OSError as e:
                installed.append(f"{name}:FAIL:{e}")
        for name, (off, fetch) in CLUTTER_FETCH.items():
            line = f"p:{name} {cmf}:{off} {fetch}\n".encode()
            try:
                os.write(fd, line)
                installed.append(name)
            except OSError as e:
                installed.append(f"{name}:FAIL:{e}")
        if gmf:
            for name, off in GTK_PROBES.items():
                line = f"p:{name} {gmf}:{off}\n".encode()
                try:
                    os.write(fd, line)
                    installed.append(name)
                except OSError as e:
                    installed.append(f"{name}:FAIL:{e}")
    finally:
        os.close(fd)
    en = TR / "events/uprobes/enable"
    if not en.is_file():
        raise SystemExit(json.dumps({"err": "uprobes not created", "installed": installed}))
    en.write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    flip_ev = TR / "events/dpu/dpu_crtc_complete_flip/enable"
    if flip_ev.parent.is_dir():
        flip_ev.write_text("1\n")
    for rel in (
        "events/drm_msm_atomic/msm_atomic_wait_flush_start/enable",
        "events/drm_msm_atomic/msm_atomic_wait_flush_finish/enable",
        "events/dpu/dpu_kms_wait_for_commit_done/enable",
        "events/dpu/dpu_enc_wait_event_timeout/enable",
        "events/drm_msm_atomic/msm_atomic_commit_tail_start/enable",
        "events/drm_msm_atomic/msm_atomic_commit_tail_finish/enable",
        "events/drm_msm_atomic/msm_atomic_flush_commit/enable",
    ):
        p = TR / rel
        if p.is_file():
            p.write_text("1\n")
    ke = TR / "kprobe_events"
    kinstalled = []
    if ke.is_file():
        try:
            ke.write_text("")
        except OSError:
            pass
        kprobes = [
            "p:dagu_ctail commit_tail",
            "p:dagu_wdep drm_atomic_helper_wait_for_dependencies",
            "p:dagu_wfence drm_atomic_helper_wait_for_fences",
        ]
        kfd = os.open(str(ke), os.O_WRONLY | os.O_APPEND)
        try:
            for line in kprobes:
                try:
                    os.write(kfd, (line + "\n").encode())
                    kinstalled.append(line.split(":", 1)[1].split()[0])
                except OSError as e:
                    kinstalled.append(f"{line}:FAIL:{e}")
        finally:
            os.close(kfd)
        for name in ("dagu_ctail", "dagu_wdep", "dagu_wfence"):
            ep = TR / f"events/kprobes/{name}/enable"
            if ep.is_file():
                ep.write_text("1\n")
    else:
        kinstalled.append("kprobe_events:absent")
    def sample_syscall(tid: int) -> str:
        try:
            raw = Path(f"/proc/{tid}/syscall").read_text().strip().split()[0]
        except OSError:
            return "gone"
        return raw

    samples: list[dict] = []
    stop = threading.Event()

    def sampler() -> None:
        while not stop.wait(0.004):
            rec = {
                "t": time.clock_gettime(time.CLOCK_MONOTONIC),
                "lab": sample_syscall(native),
                "sh": sample_syscall(pid),
            }
            samples.append(rec)

    th = threading.Thread(target=sampler, daemon=True)
    (TR / "tracing_on").write_text("1\n")
    th.start()
    time.sleep(seconds)
    stop.set()
    th.join(timeout=0.5)
    (TR / "tracing_on").write_text("0\n")
    (TR / "events/uprobes/enable").write_text("0\n")
    for name in ("dagu_ctail", "dagu_wdep", "dagu_wfence"):
        ep = TR / f"events/kprobes/{name}/enable"
        if ep.is_file():
            ep.write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    ue.write_text("")
    try:
        ke.write_text("")
    except OSError:
        pass

    ev = parse_trace(raw)
    kick, flip = ev["kick"], ev["flip"]
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        rec = {"gap_ms": round(gap, 1)}
        for key, arr in (("flip", flip), ("impl", ev["dagu_impl"]),
                         ("qcb", ev["dagu_qcb"]), ("disp", ev["dagu_disp"]),
                         ("inv", ev["dagu_inv"]), ("nview", ev["dagu_nview"]),
                         ("ifgl", ev["dagu_ifgl"]), ("mpent", ev["dagu_mpent"]),
                         ("mgo", ev["dagu_mgo"]), ("atomic", ev["dagu_atomic"]),
                         ("atmerr", ev["dagu_atmerr"]), ("ready", ev["dagu_ready"]),
                         ("wstart", ev["wstart"]), ("wfinish", ev["wfinish"]),
                         ("wcommit", ev["wcommit"]), ("tail_s", ev["tail_s"]),
                         ("tail_f", ev["tail_f"]), ("flush", ev["flush"]),
                         ("ctail", ev["ctail"]), ("wdep", ev["wdep"]),
                         ("wfence", ev["wfence"]),
                         ("npresent", ev["dagu_npresent"]),
                         ("sched", ev["dagu_sched"]),
                         ("schednow", ev["dagu_schednow"]),
                         ("fcdisp", ev["dagu_fcdisp"]),
                         ("emit", ev["dagu_emit"]),
                         ("sendcb", ev["dagu_sendcb"]),
                         ("apply", ev["dagu_apply"]),
                         ("stsked", ev["dagu_stsked"]),
                         ("stgo", ev["dagu_stgo"]),
                         ("reqph", ev["dagu_reqph"])):
            t = first_after(arr, a, b)
            rec[key] = None if t is None else round((t - a) * 1000.0, 1)
        waits = []
        for s in ev["wstart"]:
            if not (a <= s <= b):
                continue
            fin = first_after(ev["wfinish"], s, b + 0.01)
            if fin is not None:
                waits.append(round((fin - s) * 1000.0, 1))
        rec["wait_flush_ms"] = waits
        rec["qcb_all"] = [round((t - a) * 1000.0, 1) for t in ev["dagu_qcb"]
                          if a <= t <= b][:12]
        rec["disp_all"] = [round((t - a) * 1000.0, 1) for t in ev["dagu_disp"]
                           if a <= t <= b][:12]
        rec["inv_all"] = [round((t - a) * 1000.0, 1) for t in ev["dagu_inv"]
                          if a <= t <= b][:12]
        rec["emit_all"] = [round((t - a) * 1000.0, 1) for t in ev["dagu_emit"]
                           if a <= t <= b][:8]
        rec["sendcb_all"] = [round((t - a) * 1000.0, 1) for t in ev["dagu_sendcb"]
                             if a <= t <= b][:8]
        rec["apply_all"] = [round((t - a) * 1000.0, 1) for t in ev["dagu_apply"]
                            if a <= t <= b][:8]
        rec["stsked_n"] = sum(1 for t in ev["dagu_stsked"] if a <= t <= b)
        rec["stgo_n"] = sum(1 for t in ev["dagu_stgo"] if a <= t <= b)
        prev_send = None
        for t in ev["dagu_sendcb"]:
            if t < a:
                prev_send = t
            else:
                break
        rec["sendcb_before_ms"] = None if prev_send is None else round((a - prev_send) * 1000.0, 1)
        rec["reqph_all"] = [round((t - a) * 1000.0, 1) for t in ev["dagu_reqph"]
                            if a <= t <= b][:8]
        rdy = []
        for t, ready_us, _clk in ev.get("rdyt", []):
            if a <= t <= b and ready_us is not None:
                rdy.append(round(ready_us / 1000.0 - t * 1000.0, 1))
        rec["rdyt_delta_ms"] = rdy[:6]
        kind = "other"
        if rec["impl"] is not None and rec["impl"] < 15:
            if rec["nview"] is not None and rec["nview"] >= 50:
                kind = "B-main"
            elif rec["mgo"] is not None and rec["mgo"] < 15 and rec["gap_ms"] >= 50:
                if rec["atomic"] is not None and rec["atomic"] >= 50:
                    kind = "B-kick-atomic-late"
                elif rec["atomic"] is not None and rec["atomic"] < 15:
                    kind = "B-kick-kernel"
                else:
                    kind = "B-kick"
            elif rec["nview"] is not None and rec["nview"] < 15 and rec["mgo"] is not None and rec["mgo"] >= 50:
                kind = "B-post-late"
            elif rec["nview"] is None:
                kind = "B-main-no-nview"
        rec["kind"] = kind
        lab_c: Counter[str] = Counter()
        sh_c: Counter[str] = Counter()
        mid = []
        for s in samples:
            if a <= s["t"] <= b:
                lab_c[s["lab"]] += 1
                sh_c[s["sh"]] += 1
                if 10 < (s["t"] - a) * 1000.0 < gap - 10:
                    mid.append(s)
        rec["lab_sys"] = lab_c.most_common(4)
        rec["sh_sys"] = sh_c.most_common(4)
        if mid:
            rec["lab_mid"] = Counter(s["lab"] for s in mid).most_common(3)
            rec["sh_mid"] = Counter(s["sh"] for s in mid).most_common(3)
        holes.append(rec)

    sources = []
    seen = []
    mem2 = open(f"/proc/{pid}/mem", "rb", buffering=0)
    for ptr in ev.get("src_ptr", []):
        if ptr in seen or ptr < 0x10000:
            continue
        seen.append(ptr)
        try:
            mem2.seek(ptr + 32)
            ctx = struct.unpack("<Q", mem2.read(8))[0]
            mem2.seek(ptr + 40)
            prio = struct.unpack("<i", mem2.read(4))[0]
            mem2.seek(ptr + 44)
            flags = struct.unpack("<I", mem2.read(4))[0]
            mem2.seek(ptr + 128)
            mc = struct.unpack("<Q", mem2.read(8))[0]
            sources.append({"src": hex(ptr), "gsource_ctx": hex(ctx),
                            "prio": prio, "flags": hex(flags),
                            "main_context": hex(mc)})
        except OSError:
            sources.append({"src": hex(ptr), "err": "read"})
    mem2.close()

    clocks = []
    seen_clk = []
    mem3 = open(f"/proc/{pid}/mem", "rb", buffering=0)
    for _t, _ready, clk in ev.get("rdyt", []):
        if not clk or clk in seen_clk or clk < 0x10000:
            continue
        seen_clk.append(clk)
        try:
            mem3.seek(clk + 28)
            rate = struct.unpack("<f", mem3.read(4))[0]
            mem3.seek(clk + 32)
            interval = struct.unpack("<q", mem3.read(8))[0]
            mem3.seek(clk + 88)
            state = struct.unpack("<I", mem3.read(4))[0]
            mem3.seek(clk + 92)
            mode = struct.unpack("<I", mem3.read(4))[0]
            clocks.append({"clk": hex(clk), "hz": round(rate, 2),
                           "interval_us": interval, "state": state, "mode": mode})
        except OSError:
            clocks.append({"clk": hex(clk), "err": "read"})
        if len(clocks) >= 4:
            break
    mem3.close()

    out = {
        "kind": "bmain-probe",
        "tag": tag,
        "seconds": seconds,
        "pid": pid,
        "native": native,
        "mf": mf,
        "insn": insn,
        "uprobes": installed,
        "kprobes": kinstalled,
        "kickoff": gap_sum(kick),
        "flip": gap_sum(flip),
        "cmf": cmf,
        "gmf": gmf,
        "clocks": clocks,
        "rdyt_n": len(ev.get("rdyt", [])),
        "counts": {k: len(ev[k]) for k in list(PROBES) + list(CLUTTER_PROBES) +
                   list(CLUTTER_FETCH) + list(GTK_PROBES) +
                   ["kick", "flip", "wstart", "wfinish", "wcommit", "wdone",
                    "tail_s", "tail_f", "flush", "ctail", "wdep", "wfence"]},
        "wait_flush": gap_sum(ev["wstart"]),
        "sources": sources,
        "src_n": len(ev.get("src_ptr", [])),
        "sample_n": len(samples),
        "holes": holes,
        "kinds": {k: sum(1 for h in holes if h["kind"] == k)
                  for k in ("B-main", "B-kick", "B-kick-atomic-late",
                            "B-kick-kernel", "B-post-late", "B-main-no-nview",
                            "other")},
    }
    Path("/tmp/dagu-bmain-probe.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main() -> int:
    tag = ""
    args = [a for a in sys.argv[1:] if a != "--host"]
    if args:
        tag = args[0]
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-bmain-probe.py"], check=True)
    extra = f" {tag!r}" if tag else ""
    r = subprocess.run(ssh + [f"python3 /tmp/dagu-bmain-probe.py{extra}"], check=False)
    out_host = ROOT / "out" / "display-stress"
    out_host.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = out_host / f"dagu-bmain-probe-{stamp}.json"
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-bmain-probe.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    return r.returncode


def main() -> int:
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    tag = sys.argv[1] if len(sys.argv) > 1 else ""
    return on_device(tag=tag)


if __name__ == "__main__":
    raise SystemExit(main())
