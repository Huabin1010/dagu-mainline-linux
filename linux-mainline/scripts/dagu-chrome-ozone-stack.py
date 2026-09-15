#!/usr/bin/env python3
"""Live Chrome Ozone wait: sample userspace PC during DPU kickoff holes.

Does not poke. Does not enable software decode. Does not attach gdb
(469 MB chrome would freeze the board). Uses /proc/<tid>/syscall PC
+ maps file VA, then host nm/addr2line.

On tablet: python3 /usr/local/sbin/dagu-chrome-ozone-stack.py
From host: python3 linux-mainline/scripts/dagu-chrome-ozone-stack.py --host
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import time
from collections import Counter
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
OUT_HOST = ROOT / "out/display-stress"
OUT_DEV = Path("/var/log/dagu-dpu")
TR = Path("/sys/kernel/debug/tracing")
CHROME_HOST = ROOT / "out/chromium-v4l2-src/official-152/out/dagu/chrome"
WATCH = (
    "VizCompositorTh",
    "CrGpuMain",
    "Chrome_IOThread",
    "VizCompositorThread",
    "Compositor",
    "Chrome_ChildIOT",
    "GpuVSyncThread",
    "ThreadPoolForeg",
)
OZONE_HINTS = (
    (0x3532274, 0x35327F4, "WaylandFrameManager::MaybeProcessPendingFrame"),
    (0x3532604, 0x353263C, "MaybeProcessPendingFrame.WaitForFrameCallback"),
    (0x3532314, 0x3532318, "MaybeProcessPendingFrame.tbz_feedback"),
    (0x35327F4, 0x3534300, "WaylandFrameManager::PlayBackFrame"),
    (0x3534348, 0x353437C, "WaylandFrameManager::FrameCallbackTimeout"),
    (0x353437C, 0x35348B0, "WaylandFrameManager::OnExplicitBufferRelease"),
    (0x35348B0, 0x3534C44, "WaylandFrameManager::OnDiscarded"),
    (0x3534C44, 0x3535200, "WaylandFrameManager::HandlePresentationFeedback"),
    (0x35485C8, 0x3548A2C, "WaylandSyncobjTimeline::IncrementSyncPoint"),
    (0x3548A2C, 0x3548CE0, "WaylandSyncobjReleaseTimeline::IncrementSyncPoint"),
    (0x3548CE0, 0x3548F80, "WaylandSyncobjReleaseTimeline::WaitForFenceAvailable"),
    (0x3507714, 0x35077FC, "BeginFrameSourceWayland::SetNeedsBeginFrame"),
    (0x35077FC, 0x3507B78, "BeginFrameSourceWayland::MaybeIssueBeginFrame"),
    (0x3507B88, 0x3507C54, "BeginFrameSourceWayland::OnFrameCallback"),
    (0x3507C54, 0x3507EB0, "BeginFrameSourceWayland::OnPresentationFeedback"),
    (0x3507EB0, 0x3507F80, "BeginFrameSourceWayland::OnBeginFrameAck"),
    (0x3507F80, 0x3508080, "BeginFrameSourceWayland::StartFrameCallbackTimer"),
    (0x3508080, 0x3508138, "BeginFrameSourceWayland::OnFrameCallbackTimeout"),
    (0x34FFD74, 0x3501000, "WaylandBufferManagerGpu::OnSubmission"),
    (0x3510B0C, 0x3512000, "WaylandBufferManagerHost::OnSubmission"),
    (0x35740D4, 0x357438C, "GbmSurfacelessWayland::OnSubmission"),
    (0xBC66330, 0xBC69000, "viz::Display::DrawAndSwap"),
)
LINE_RE = re.compile(
    r"^\s*(?P<comm>\S+)-(?P<pid>\d+)\s+\[\d+\]\s+\S+\s+(?P<ts>[\d.]+):\s+(?P<ev>\S+):"
)
BUILDID_EXPECT = "858b8197c2ea8f42e85174323b0fa5ee49eeaae1"


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def find_gpu() -> dict:
    out: dict = {"gpu": None, "browser": None, "threads": [], "maps": None, "inode": None}
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if b"/usr/lib/chromium/chromium" not in cmd:
            continue
        pid = int(p.name)
        if b"type=gpu-process" in cmd:
            out["gpu"] = pid
            out["gpu_cmd"] = cmd.replace(b"\x00", b" ").decode("utf-8", "replace")[:400]
        elif b"type=" not in cmd:
            out["browser"] = pid
    gpu = out.get("gpu")
    if not gpu:
        return out
    for line in read_text(Path(f"/proc/{gpu}/maps")).splitlines():
        if "r-xp" in line and "/usr/lib/chromium/chromium" in line:
            start_s, end_s = line.split()[0].split("-")
            off = int(line.split()[2], 16)
            inode = int(line.split()[4])
            # official-152 RX LOAD: p_offset=0x2ba0000 p_vaddr=0x2bb0000
            # runtime = maps_start + (elf_va - p_vaddr)
            out["maps"] = {
                "start": int(start_s, 16),
                "end": int(end_s, 16),
                "off": off,
                "vaddr": off + 0x10000 if off == 0x2BA0000 else off,
                "line": line,
            }
            out["inode"] = inode
            break
    tdir = Path(f"/proc/{gpu}/task")
    if tdir.is_dir():
        for t in tdir.iterdir():
            try:
                comm = (t / "comm").read_text().strip()
            except OSError:
                continue
            if comm in WATCH or "gdrv" in comm or "Wayland" in comm or "VSync" in comm:
                out["threads"].append({"tid": int(t.name), "comm": comm})
    return out


def parse_syscall(tid: int) -> dict:
    raw = read_text(Path(f"/proc/{tid}/syscall")).strip()
    wchan = read_text(Path(f"/proc/{tid}/wchan")).strip()[:64] or "?"
    rec = {"tid": tid, "wchan": wchan, "sys": raw[:80], "nr": None, "pc": None}
    if not raw or raw == "running":
        rec["nr"] = "running"
        return rec
    parts = raw.split()
    if not parts:
        return rec
    rec["nr"] = parts[0]
    if len(parts) >= 2:
        try:
            rec["pc"] = int(parts[-1], 16)
        except ValueError:
            rec["pc"] = None
    return rec


def file_va(pc: int | None, maps: dict | None) -> int | None:
    if pc is None or not maps:
        return None
    if maps["start"] <= pc < maps["end"]:
        return pc - maps["start"] + maps.get("vaddr", maps["off"])
    return None


def hint_name(va: int | None) -> str | None:
    if va is None:
        return None
    for lo, hi, name in OZONE_HINTS:
        if lo <= va < hi:
            return name
    return None


def arm_trace() -> None:
    (TR / "tracing_on").write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("8192\n")
    (TR / "events/dpu/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")


def stop_trace() -> str:
    (TR / "tracing_on").write_text("0\n")
    return (TR / "trace").read_text(errors="replace")


def kick_ts(trace: str) -> list[float]:
    out = []
    for line in trace.splitlines():
        m = LINE_RE.match(line)
        if m and m.group("ev") == "dpu_enc_kickoff":
            out.append(float(m.group("ts")))
    return out


def gaps(ts: list[float]) -> list[tuple[float, float, float]]:
    holes = []
    for a, b in zip(ts, ts[1:]):
        gap = (b - a) * 1000.0
        if gap > 50.0:
            holes.append((a, b, round(gap, 2)))
    return holes


def read_buildid() -> str:
    try:
        data = Path("/usr/lib/chromium/chromium").read_bytes()[:4096]
    except OSError:
        return ""
    # ELF note is later; fall back to readelf-less scan of first 8K is useless.
    # Use /sys or python elf note via os.
    try:
        import struct

        with Path("/usr/lib/chromium/chromium").open("rb") as f:
            ehdr = f.read(64)
            if ehdr[0:4] != b"\x7fELF":
                return ""
            phoff = struct.unpack_from("<Q", ehdr, 32)[0]
            phentsize, phnum = struct.unpack_from("<HH", ehdr, 54)
            f.seek(phoff)
            for _ in range(phnum):
                ph = f.read(phentsize)
                p_type, = struct.unpack_from("<I", ph, 0)
                if p_type != 4:  # PT_NOTE
                    continue
                off, filesz = struct.unpack_from("<QQ", ph, 8)
                f.seek(off)
                note = f.read(filesz)
                pos = 0
                while pos + 12 <= len(note):
                    namesz, descsz, ntype = struct.unpack_from("<III", note, pos)
                    pos += 12
                    name = note[pos:pos + namesz]
                    pos = (pos + namesz + 3) & ~3
                    desc = note[pos:pos + descsz]
                    pos = (pos + descsz + 3) & ~3
                    if ntype == 3 and b"GNU" in name and len(desc) >= 20:
                        return desc[:20].hex()
    except Exception:
        return ""
    return ""


def peek_insn(pid: int, maps: dict, va: int) -> str | None:
    addr = maps["start"] + (va - maps.get("vaddr", maps["off"]))
    try:
        with open(f"/proc/{pid}/mem", "rb", buffering=0) as mem:
            mem.seek(addr)
            raw = mem.read(4)
        if len(raw) != 4:
            return None
        return f"0x{int.from_bytes(raw, 'little'):08x}"
    except OSError:
        return None


def on_device() -> int:
    OUT_DEV.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = OUT_DEV / f"ozone-stack-{stamp}"
    dest.mkdir(parents=True, exist_ok=True)

    info = find_gpu()
    maps = info.get("maps")
    gpu = info.get("gpu")
    if not gpu or not maps:
        (dest / "error.json").write_text(json.dumps({"error": "no gpu/maps", "info": info}, indent=2))
        print("no gpu-process / chromium r-xp maps", file=sys.stderr)
        return 2

    bid = read_buildid()
    insn = {
        "MaybeProcessPendingFrame": peek_insn(gpu, maps, 0x3532274),
        "tbz_feedback_3532314": peek_insn(gpu, maps, 0x3532314),
        "WaitForFrameCallback_3532604": peek_insn(gpu, maps, 0x3532604),
        "FrameCallbackTimeout": peek_insn(gpu, maps, 0x3534348),
        "WaitForFenceAvailable": peek_insn(gpu, maps, 0x3548CE0),
    }

    threads = info["threads"]
    samples: list[dict] = []
    stop = threading.Event()

    def sampler() -> None:
        while not stop.is_set():
            t = time.monotonic()
            row = {"t": t, "th": []}
            for th in threads:
                rec = parse_syscall(th["tid"])
                rec["comm"] = th["comm"]
                rec["va"] = file_va(rec["pc"], maps)
                rec["hint"] = hint_name(rec["va"])
                row["th"].append(rec)
            samples.append(row)
            time.sleep(0.002)

    arm_trace()
    th = threading.Thread(target=sampler, daemon=True)
    th.start()
    time.sleep(8.0)
    stop.set()
    th.join(timeout=1.0)
    trace = stop_trace()
    (dest / "trace.txt").write_text(trace)
    kicks = kick_ts(trace)
    holes = gaps(kicks)

    hole_rows = []
    for t0, t1, gap in holes:
        near = [s for s in samples if t0 <= s["t"] <= t1]
        wchans: Counter[str] = Counter()
        hints: Counter[str] = Counter()
        vas: Counter[str] = Counter()
        nrs: Counter[str] = Counter()
        for s in near:
            for rec in s["th"]:
                key = f"{rec['comm']}:{rec['wchan']}"
                wchans[key] += 1
                nrs[f"{rec['comm']}:{rec['nr']}"] += 1
                if rec.get("hint"):
                    hints[f"{rec['comm']}:{rec['hint']}"] += 1
                if rec.get("va") is not None:
                    vas[f"{rec['comm']}:0x{rec['va']:x}"] += 1
        hole_rows.append({
            "t0": t0,
            "t1": t1,
            "gap_ms": gap,
            "samples": len(near),
            "wchan": dict(wchans.most_common(16)),
            "nr": dict(nrs.most_common(16)),
            "hint": dict(hints.most_common(16)),
            "va": dict(vas.most_common(24)),
        })

    # Whole-window hint histogram (not just holes)
    all_hints: Counter[str] = Counter()
    all_va: Counter[str] = Counter()
    all_wchan: Counter[str] = Counter()
    for s in samples:
        for rec in s["th"]:
            all_wchan[f"{rec['comm']}:{rec['wchan']}"] += 1
            if rec.get("hint"):
                all_hints[f"{rec['comm']}:{rec['hint']}"] += 1
            if rec.get("va") is not None:
                all_va[f"{rec['comm']}:0x{rec['va']:x}"] += 1

    span = (kicks[-1] - kicks[0]) if len(kicks) > 1 else 8.0
    kg = [(b - a) * 1000.0 for a, b in zip(kicks, kicks[1:])]
    report = {
        "stamp": stamp,
        "buildid": bid,
        "buildid_expect": BUILDID_EXPECT,
        "buildid_ok": bid == BUILDID_EXPECT,
        "inode": info.get("inode"),
        "maps": maps,
        "gpu": gpu,
        "gpu_cmd": info.get("gpu_cmd", "")[:400],
        "bfs_in_cmd": "WaylandExternalBeginFrameSource" in (info.get("gpu_cmd") or ""),
        "syncobj_in_cmd": "WaylandLinuxDrmSyncobj" in (info.get("gpu_cmd") or ""),
        "threads": threads,
        "insn": insn,
        "sample_n": len(samples),
        "kick_n": len(kicks),
        "kick_hz": round(len(kicks) / max(span, 1e-6), 1),
        "kick_max_ms": round(max(kg), 2) if kg else None,
        "gt50": len(holes),
        "holes": hole_rows,
        "hint_all": dict(all_hints.most_common(20)),
        "va_all": dict(all_va.most_common(40)),
        "wchan_all": dict(all_wchan.most_common(24)),
    }
    (dest / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps({
        "dest": str(dest),
        "buildid_ok": report["buildid_ok"],
        "bfs": report["bfs_in_cmd"],
        "syncobj": report["syncobj_in_cmd"],
        "kick_hz": report["kick_hz"],
        "kick_max_ms": report["kick_max_ms"],
        "gt50": report["gt50"],
        "insn": insn,
        "holes": [
            {"gap_ms": h["gap_ms"], "hint": h["hint"], "wchan": h["wchan"]}
            for h in hole_rows
        ],
        "hint_all": report["hint_all"],
    }, indent=2))
    return 0


def symbolicate(report_path: Path) -> dict:
    data = json.loads(report_path.read_text())
    vas: set[int] = set()
    for h in data.get("holes", []):
        for key in h.get("va", {}):
            try:
                vas.add(int(key.rsplit(":", 1)[1], 16))
            except (IndexError, ValueError):
                pass
    for key in data.get("va_all", {}):
        try:
            vas.add(int(key.rsplit(":", 1)[1], 16))
        except (IndexError, ValueError):
            pass
    names = {}
    if CHROME_HOST.is_file() and vas:
        addrs = "\n".join(f"{v:x}" for v in sorted(vas))
        proc = subprocess.run(
            ["aarch64-linux-gnu-addr2line", "-e", str(CHROME_HOST), "-f", "-C", "-p"],
            input=addrs, text=True, capture_output=True, check=False,
        )
        lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
        for va, line in zip(sorted(vas), lines):
            names[f"0x{va:x}"] = line
    data["addr2line"] = names
    out = report_path.with_name(report_path.stem + "-sym.json")
    out.write_text(json.dumps(data, indent=2))
    return {"out": str(out), "n": len(names), "holes": data.get("gt50"), "kick_hz": data.get("kick_hz")}


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--symbolicate":
        path = Path(sys.argv[2])
        print(json.dumps(symbolicate(path), indent=2))
        return 0
    if len(sys.argv) > 1 and sys.argv[1] == "--host":
        remote = "/usr/local/sbin/dagu-chrome-ozone-stack.py"
        subprocess.run(
            ssh_base() + [f"cat >{remote} && chmod 755 {remote}"],
            input=Path(__file__).read_bytes(),
            check=True,
        )
        proc = subprocess.run(ssh_base() + ["python3", remote], check=False)
        OUT_HOST.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null", "-r",
                f"root@{HOST}:{OUT_DEV}/ozone-stack-*",
                str(OUT_HOST) + "/",
            ],
            check=False,
        )
        latest = sorted(OUT_HOST.glob("ozone-stack-*/report.json"))
        if latest:
            print(json.dumps(symbolicate(latest[-1]), indent=2))
        return proc.returncode
    return on_device()


if __name__ == "__main__":
    raise SystemExit(main())
