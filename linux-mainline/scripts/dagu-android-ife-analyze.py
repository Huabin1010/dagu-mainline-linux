#!/usr/bin/env python3
"""Read-only Titan 480 IFE analyzer for the HyperOS dagu tablet.

Purpose: turn a live Android preview session into a ranked gap list for
Linux CAMSS PIX linear NV12. This is not a SoftISP path and it never
flashes the Android unit.

Usage:
  DAGU_ADB_SERIAL=53dcc70 ./scripts/dagu-android-ife-analyze.py
  ./scripts/dagu-android-ife-analyze.py --offline dumps/dagu-android-live/camera-ife-20260916

Refuses Linux pad serial ab22268c and any 18d1:d00d fastboot device.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

LINUX_PAD_SERIAL = "ab22268c"
FASTBOOT_VIDPID = "18d1:d00d"
ADB_VIDPID = "18d1:4ee7"

# CAF cam_vfe480.h BUS clients. Packer enum matches cam_vfe_bus_ver3.c.
PACKER_NAME = {
    0: "PLAIN_128",
    1: "PLAIN_8",
    2: "PLAIN_8_ODD_EVEN",
    3: "PLAIN_8_LSB_MSB_10",
    4: "PLAIN_8_LSB_MSB_10_ODD_EVEN",
}
WM_NAME = {
    0: "FULL_Y",
    1: "FULL_C",
    4: "DISP_Y",
    5: "DISP_C",
    6: "DISP_DS4",
    7: "DISP_DS16",
    8: "FD_Y",
    9: "FD_C",
    23: "RDI0",
    24: "RDI1",
}

# Display Full CLC from camera.qcom.so CreateCmdList (Linux overlay comments).
CLC_DISPLAY = [
    ("CST", 0x4000, "Linux EN"),
    ("RoundClamp PRE", 0x4200, "Linux EN 0x3c01"),
    ("Crop11 Y", 0x4400, "Linux keep-all"),
    ("Crop11 C", 0x4600, "Linux keep-all 4080x1530"),
    ("RoundClamp MID Y", 0x4800, "Linux EN=0 — next CLC gap"),
    ("RoundClamp MID C", 0x4A00, "Linux EN=0 — next CLC gap"),
    ("MNDS Y DISP", 0x4C00, "Linux 1920x1080"),
    ("MNDS C DISP", 0x4E00, "Linux V_IN=in_h/2"),
    ("RoundClamp POST Y", 0x5000, "Linux EN 0x3c01"),
    ("RoundClamp POST C", 0x5200, "Linux EN 0x3c01"),
]

UBWC_STATIC_LPDDR5 = 0x1036  # kona-camera.dtsi ubwc-static-cfg[1]


@dataclass
class WmClient:
    index: int
    en_cfg: int | None = None
    width: int | None = None
    height: int | None = None
    stride: int | None = None
    frame_inc: int | None = None
    ubwc: bool = False
    meta: int | None = None
    slice_h: int | None = None
    addr: str | None = None
    h_init: int | None = None
    packer: int | None = None
    burst: int | None = None
    src: str | None = None


@dataclass
class Capture:
    serial: str
    camera_active: bool = False
    graph: str | None = None
    softisp: bool = False
    irq: dict[str, int] = field(default_factory=dict)
    wms: dict[int, WmClient] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)
    mem_blocked: bool = True
    regdump_files: list[str] = field(default_factory=list)


def die(msg: str) -> None:
    raise SystemExit(f"dagu-android-ife-analyze: {msg}")


def run(
    args: list[str],
    check: bool = True,
    text: bool = True,
    timeout: float = 30,
) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            args, check=check, text=text, capture_output=True, timeout=timeout
        )
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or "") + (e.stderr or "")
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        return subprocess.CompletedProcess(
            args, 124, out, f"timeout {timeout}s: {' '.join(args)}\n"
        )


def adb(serial: str, *args: str, check: bool = True, timeout: float = 30) -> str:
    r = run(["adb", "-s", serial, *args], check=check, timeout=timeout)
    if check is False and r.returncode:
        return (r.stdout or "") + (r.stderr or "")
    return r.stdout or ""


def su(serial: str, cmd: str, check: bool = True, timeout: float = 20) -> str:
    # One adb-shell string so Magisk su sees redirects.
    wrapped = "su -c " + repr(cmd)
    r = run(["adb", "-s", serial, "shell", wrapped], check=False, timeout=timeout)
    text = (r.stdout or "") + (r.stderr or "")
    if check and r.returncode:
        die(f"su failed rc={r.returncode}: {cmd}\n{text}")
    return text if not check else (r.stdout or "")


def assert_android_pad(serial: str) -> None:
    if serial == LINUX_PAD_SERIAL:
        die(f"refusing Linux pad serial {LINUX_PAD_SERIAL} (B-slot machine)")
    got = adb(serial, "get-serialno").strip()
    if got != serial:
        die(f"adb serial is {got!r}, expected {serial!r}")
    lsusb = run(["lsusb"], check=False).stdout
    if FASTBOOT_VIDPID in lsusb and serial.lower() in lsusb.lower():
        die(f"{FASTBOOT_VIDPID} present — will not talk to a fastboot dagu")
    # HyperOS extract pad is 18d1:4ee7. Linux g_serial is 0525:a4a7.
    props = su(serial, "getprop ro.product.device; getprop ro.build.version.release")
    if "dagu" not in props:
        die(f"device is not dagu:\n{props}")


def parse_image_cfg(val: int) -> tuple[int, int]:
    return val & 0xFFFF, (val >> 16) & 0xFFFF


# Display Full linear dest (CamX MNDS 2314×1314 padded to 2320×1320).
DISP_FULL_CROP_LAST = 0x0A1F05BF
DISP_FULL_PHASE_Y = 0xC023D82C
DISP_FULL_PHASE_C = 0xC047B058
DISP_FULL_RC_LAST_X = 0x090F
DISP_FULL_RC_LAST_Y = 0x0527
CROP_640_PHASE = 0xC081999A
IDENTITY_CROP_LAST = 0x0A1F079F
# Topology XML (Extensible Markup Language，可扩展标记语言) mixed DAG
# (Directed Acyclic Graph，有向无环图) leftovers that Linux CAMSS
# (Camera Subsystem，相机子系统) must not replay onto WM
# (Write Master，AXI 写通道) 4/5.
FORBIDDEN_RC_640 = {0x01DF, 0x027F, 0x00EF, 0x013F, 0x01E7, 0x0287}


def classify_cdm_port(addr: int) -> str:
    """Tag one AHB (Advanced High-performance Bus，高级高性能总线) pack
    by Topology XML (Extensible Markup Language，可扩展标记语言) port.
    """
    if 0x4000 <= addr < 0x5400 or 0x5800 <= addr < 0x5C00:
        return "DISP"
    if 0x5400 <= addr < 0x5800 or 0x5C00 <= addr < 0x6400:
        return "TAP"
    if 0x7E00 <= addr < 0x8000:
        return "FD"
    if 0x8000 <= addr < 0xA000:
        return "stats"
    if 0xAA00 <= addr < 0xC000:
        return "BUS"
    return "other"


def pack_is_forbidden(addr: int, vals: list[int]) -> str | None:
    if any(v == CROP_640_PHASE for v in vals[:6]):
        return "Crop 640 0xc081999a"
    if addr in (0x4460, 0x4660, 0x4C60, 0x4E60) and vals:
        last = vals[2] if len(vals) > 2 else None
        if last == IDENTITY_CROP_LAST:
            return "identity last 0x0a1f079f (ZSL UBWC/IPE graph)"
    if addr in (0x4868, 0x4A68, 0x5068, 0x5268, 0x5868, 0x5A68):
        if any(v in FORBIDDEN_RC_640 for v in vals[:4]):
            return "RC dest 640/488 (viewfinder TAP/FD leftover)"
    if 0x5400 <= addr < 0x6400:
        return "TAP/DS64"
    if 0x7E00 <= addr < 0x8000:
        return "FD"
    if 0x8000 <= addr < 0xA000:
        return "stats"
    return None


def pack_is_disp_linear(addr: int, vals: list[int]) -> bool:
    if addr in (0x4400, 0x4460, 0x4600, 0x4660, 0x4C00, 0x4C60, 0x4E00, 0x4E60):
        if len(vals) >= 4 and vals[2] == DISP_FULL_CROP_LAST:
            if vals[3] in (DISP_FULL_PHASE_Y, DISP_FULL_PHASE_C, 0xC0200000, 0xC0400000):
                if CROP_640_PHASE not in vals:
                    return True
    if addr in (0x4868, 0x4A68, 0x5068, 0x5268, 0x5868, 0x5A68):
        if DISP_FULL_RC_LAST_X in vals or DISP_FULL_RC_LAST_Y in vals:
            return True
        if 0x08FF in vals and 0x050F in vals:
            return True
    return False


def parse_heap_display_full(text: str) -> list[dict]:
    """Parse process_vm heap Crop 9-word (Display Full packet, not 1MB first-list)."""
    hits: list[dict] = []
    if "0a1f05bf" in text and "c023d82c" in text:
        hits.append(
            {
                "src": "heap",
                "port": "DISP",
                "keep": True,
                "note": "Crop Y last 0x0a1f05bf phase 0xc023d82c",
            }
        )
    if "0a1f05bf" in text and "c047b058" in text:
        hits.append(
            {
                "src": "heap",
                "port": "DISP",
                "keep": True,
                "note": "Crop C last 0x0a1f05bf phase 0xc047b058",
            }
        )
    return hits


def parse_sensor_module_modes(path: Path) -> dict:
    """IFE-relevant WxH in the CamX sensor module. delayUs / I2C 0x0900 are not dest."""
    import struct

    data = path.read_bytes()
    modes: list[dict] = []
    for i in range(0, len(data) - 16, 4):
        w = struct.unpack_from("<I", data, i)[0]
        if w != 2592:
            continue
        h = struct.unpack_from("<I", data, i + 8)[0]
        if h in (1952, 1472):
            extra = struct.unpack_from("<I", data, i - 8)[0] if i >= 8 else 0
            modes.append(
                {
                    "off": i,
                    "w": w,
                    "h": h,
                    "before": extra,
                }
            )
    delay_false = []
    for val, name in (
        (1296, "1296"),
        (1314, "1314"),
        (1320, "1320"),
        (1458, "1458"),
        (1920, "1920"),
        (1080, "1080"),
    ):
        n = struct.pack("<I", val)
        start = 0
        while True:
            i = data.find(n, start)
            if i < 0:
                break
            around = data[i : i + 24]
            if b"delayUs" in around or b"delayUs" in data[i + 4 : i + 20]:
                delay_false.append(name)
                break
            start = i + 4
    return {
        "path": str(path),
        "modes": modes,
        "delayUs_not_dest": sorted(set(delay_false)),
        "has_2304x1296_pair": False,
    }


# Titan 480 BUS WM n = 0xaa00 + 0x200 + n*0x100.
BUS_WM_BASE = 0xAC00
BUS_WM_STRIDE = 0x100
WM_OFF_CFG = 0x00
WM_OFF_ADDR = 0x04
WM_OFF_FRAME_INCR = 0x08
WM_OFF_CFG0 = 0x0C
WM_OFF_CFG1 = 0x10
WM_OFF_CFG2 = 0x14
WM_OFF_PACKER = 0x18
WM_OFF_BURST = 0x1C


def bus_wm_index(addr: int) -> int | None:
    if addr < BUS_WM_BASE or addr >= 0xC000:
        return None
    return (addr - BUS_WM_BASE) // BUS_WM_STRIDE


def parse_cdm_ahb(path: Path, out: Path | None = None) -> list[dict]:
    """Walk Titan 480 CDM opcode-3 REG_CONT and opcode-4 REG_RANDOM."""
    import struct

    data = path.read_bytes()
    nw = len(data) // 4
    words = struct.unpack(f"<{nw}I", data[: nw * 4])
    packs: list[dict] = []
    i = 0
    while i + 1 < nw:
        cmd = words[i]
        op = (cmd >> 24) & 0xFF
        n = cmd & 0xFF
        if op == 3 and 1 <= n <= 64 and words[i + 1] < 0x20000:
            addr = words[i + 1]
            vals = list(words[i + 2 : i + 2 + n])
            port = classify_cdm_port(addr)
            packs.append(
                {
                    "off": i,
                    "op": 3,
                    "addr": addr,
                    "n": n,
                    "vals": vals,
                    "pairs": None,
                    "port": port,
                    "keep": pack_is_disp_linear(addr, vals),
                    "forbid": pack_is_forbidden(addr, vals),
                }
            )
            i += 2 + n
            continue
        if op == 4 and 1 <= n <= 128 and i + 1 + 2 * n <= nw:
            pairs: list[tuple[int, int]] = []
            ok = True
            for k in range(n):
                a = words[i + 1 + 2 * k]
                v = words[i + 2 + 2 * k]
                if a >= 0x20000:
                    ok = False
                    break
                pairs.append((a, v))
            if ok and pairs:
                addr = pairs[0][0]
                vals = [v for _, v in pairs]
                port = classify_cdm_port(addr)
                packs.append(
                    {
                        "off": i,
                        "op": 4,
                        "addr": addr,
                        "n": n,
                        "vals": vals,
                        "pairs": pairs,
                        "port": port,
                        "keep": False,
                        "forbid": None,
                    }
                )
                i += 1 + 2 * n
                continue
        i += 1
    if out is not None:
        lines = [
            f"cdm {path} bytes={len(data)} ahb={len(packs)}",
            "op3=REG_CONT Crop/MNDS 9-word; op4=REG_RANDOM live WM 4/5",
            "port tags: DISP=WM4/5 dest, TAP=WM6/7, FD=WM8/9, stats, BUS",
            "keep=Display Full linear (Crop 0x0a1f05bf + phase 0xc023d82c / RC 0x527/0x90f)",
        ]
        by_port: dict[str, int] = {}
        by_op: dict[int, int] = {}
        keep_n = 0
        for p in packs:
            by_port[p["port"]] = by_port.get(p["port"], 0) + 1
            by_op[p["op"]] = by_op.get(p["op"], 0) + 1
            if p["keep"]:
                keep_n += 1
        lines.append(
            "counts "
            + " ".join(f"{k}={v}" for k, v in sorted(by_port.items()))
            + " "
            + " ".join(f"op{k}={v}" for k, v in sorted(by_op.items()))
            + f" disp_linear={keep_n}"
        )
        for p in packs:
            vs = " ".join(f"{v:08x}" for v in p["vals"][:8])
            tag = "KEEP" if p["keep"] else ("FORBID " + (p["forbid"] or p["port"]))
            lines.append(
                f"@{p['off']:5d} op{p['op']} {p['port']:5s} {tag:28s} "
                f"addr=0x{p['addr']:04x} n={p['n']} {vs}"
            )
        wms = extract_cdm_wms(packs)
        lines.append("## opcode 4 last WM (Write Master，AXI 写通道)")
        for idx in sorted(wms):
            c = wms[idx]
            kind = "UBWC" if c.ubwc else "linear"
            cfg0 = (
                hex((c.height << 16) | c.width)
                if c.width is not None and c.height is not None
                else "?"
            )
            lines.append(
                f"WM{idx} {kind} {c.width}x{c.height} stride={c.stride} "
                f"frame_inc={c.frame_inc} packer={c.packer} burst={c.burst} cfg0={cfg0} "
                f"h_init={c.h_init}"
            )
        out.write_text("\n".join(lines) + "\n")
    return packs


def extract_cdm_wms(packs: list[dict]) -> dict[int, WmClient]:
    """Last-write WM table from opcode-4 REG_RANDOM BUS pairs."""
    last: dict[int, dict[int, int]] = {}
    for p in packs:
        if p.get("op") != 4 or not p.get("pairs"):
            continue
        for addr, val in p["pairs"]:
            idx = bus_wm_index(addr)
            if idx is None:
                continue
            off = addr - (BUS_WM_BASE + idx * BUS_WM_STRIDE)
            last.setdefault(idx, {})[off] = val
    wms: dict[int, WmClient] = {}
    for idx, regs in last.items():
        c = WmClient(index=idx, src="cdm-op4")
        if WM_OFF_CFG in regs:
            c.en_cfg = regs[WM_OFF_CFG]
        if WM_OFF_CFG0 in regs:
            c.width, c.height = parse_image_cfg(regs[WM_OFF_CFG0])
        if WM_OFF_CFG1 in regs:
            c.h_init = regs[WM_OFF_CFG1]
        if WM_OFF_CFG2 in regs:
            c.stride = regs[WM_OFF_CFG2]
        if WM_OFF_FRAME_INCR in regs:
            c.frame_inc = regs[WM_OFF_FRAME_INCR]
        if WM_OFF_PACKER in regs:
            c.packer = regs[WM_OFF_PACKER]
            # Live Camera ID 1 identity uses packer 0xb (UBWC). Linear is 1/3.
            c.ubwc = c.packer not in (1, 3)
        if WM_OFF_BURST in regs:
            c.burst = regs[WM_OFF_BURST]
        if WM_OFF_ADDR in regs:
            c.addr = hex(regs[WM_OFF_ADDR])
        wms[idx] = c
    return wms


def merge_cdm_wms(cap: Capture, cdm_wms: dict[int, WmClient]) -> None:
    if not cdm_wms:
        return
    filled = 0
    for idx, src in cdm_wms.items():
        dst = cap.wms.get(idx)
        if dst is None:
            cap.wms[idx] = src
            filled += 1
            continue
        if dst.width is None:
            dst.width, dst.height = src.width, src.height
        if dst.stride is None:
            dst.stride = src.stride
        if dst.frame_inc is None:
            dst.frame_inc = src.frame_inc
        if dst.packer is None:
            dst.packer = src.packer
        if dst.burst is None:
            dst.burst = src.burst
        if src.ubwc:
            dst.ubwc = True
        if dst.h_init is None:
            dst.h_init = src.h_init
        if dst.en_cfg is None:
            dst.en_cfg = src.en_cfg
        if dst.src is None:
            dst.src = src.src
    y = cdm_wms.get(4)
    c = cdm_wms.get(5)
    if y and c:
        cap.notes.append(
            "CDM（Camera Data Mover，相机命令搬运器）opcode 4 WM（Write Master，AXI 写通道）"
            f"4/5 {y.width}x{y.height}/{c.width}x{c.height} "
            f"stride={y.stride} packer={y.packer} "
            f"{'UBWC（Universal Bandwidth Compression，高通带宽压缩）' if y.ubwc else 'linear'}"
        )
    elif filled:
        cap.notes.append(
            f"CDM（Camera Data Mover，相机命令搬运器）opcode 4 filled {filled} "
            "WM（Write Master，AXI 写通道）"
        )


def disp_linear_subset(
    packs: list[dict], heap_hits: list[dict]
) -> list[dict]:
    found = [p for p in packs if p.get("keep")]
    found.extend(heap_hits)
    return found


def parse_wm_dmesg(text: str) -> dict[int, WmClient]:
    wms: dict[int, WmClient] = {}

    def wm(idx: int) -> WmClient:
        return wms.setdefault(idx, WmClient(index=idx))

    for m in re.finditer(
        r"WM:(\d+) en_cfg (0x[0-9A-Fa-f]+)", text
    ):
        wm(int(m.group(1))).en_cfg = int(m.group(2), 16)
    for m in re.finditer(
        r"WM:(\d+) image height and width (0x[0-9A-Fa-f]+)", text
    ):
        w, h = parse_image_cfg(int(m.group(2), 16))
        c = wm(int(m.group(1)))
        c.width, c.height = w, h
    for m in re.finditer(
        r"WM:(\d+) ubwc meta addr (0x[0-9A-Fa-f]+)", text
    ):
        c = wm(int(m.group(1)))
        c.ubwc = True
        c.addr = m.group(2)
    for m in re.finditer(
        r"WM:(\d+) frm (\d+): ht: (\d+) stride (\d+) meta: (\d+)", text
    ):
        c = wm(int(m.group(1)))
        c.ubwc = True
        c.frame_inc = int(m.group(2))
        c.slice_h = int(m.group(3))
        c.stride = int(m.group(4))
        c.meta = int(m.group(5))
    for m in re.finditer(r"WM:(\d+) frame_inc (\d+)", text):
        c = wm(int(m.group(1)))
        if c.frame_inc is None:
            c.frame_inc = int(m.group(2))
    for m in re.finditer(r"WM:(\d+) h_init (0x[0-9A-Fa-f]+)", text):
        wm(int(m.group(1))).h_init = int(m.group(2), 16)
    current_wm: int | None = None
    for line in text.splitlines():
        tagged = re.search(r"WM:(\d+) ", line)
        if tagged:
            current_wm = int(tagged.group(1))
        stride = re.search(r"before stride (\d+)", line)
        if stride and current_wm is not None:
            c = wm(current_wm)
            if c.stride is None:
                c.stride = int(stride.group(1))
    for m in re.finditer(r"WM:(\d+) image address (0x[0-9A-Fa-f]+)", text):
        c = wm(int(m.group(1)))
        if c.addr is None:
            c.addr = m.group(2)
    for m in re.finditer(
        r"WM:(\d+) image stride (0x[0-9A-Fa-f]+|\d+)", text
    ):
        c = wm(int(m.group(1)))
        raw = m.group(2)
        c.stride = int(raw, 16) if raw.startswith("0x") else int(raw)
    return wms


def parse_irqs(text: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for line in text.splitlines():
        if not re.search(r"\b(ife|csid)\b", line, re.I):
            continue
        nums = [int(x) for x in re.findall(r"\b\d+\b", line)]
        # /proc/interrupts: irq-index then per-cpu counts then GIC number.
        if len(nums) < 3:
            continue
        total = sum(nums[1:-1]) if nums[-1] > 32 else sum(nums[1:])
        name = line.split()[-1]
        out[name] = total
    return out


def parse_graph(logcat: str) -> tuple[str | None, bool]:
    graph = None
    m = re.search(r"(RealTimeFeature[A-Za-z0-9]+)", logcat)
    if m:
        graph = m.group(1)
    soft = bool(
        re.search(r"softispprocess|SoftISP|SWISP", logcat, re.I)
        and re.search(r"IFE_OutputPort|RealTimeFeature", logcat)
    )
    # Presence of the .so on the filesystem is not this path. Only flag
    # SoftISP if CamX actually named it as the running graph.
    if graph and "SoftIsp" in graph:
        soft = True
    elif graph:
        soft = False
    return graph, soft


def linux_overlay_facts(root: Path) -> dict:
    overlay = (
        root
        / "overlays/linux/drivers/media/platform/qcom/camss/camss-vfe-480.c"
    )
    text = overlay.read_text(errors="replace") if overlay.exists() else ""
    return {
        "packer3": "PACKER_PLAIN_8_LSB_MSB_10" in text,
        "ubwc_static": "UBWC_STATIC_LPDDR5" in text and "0x1036" in text,
        "ubwc_mode_off": "VFE_BUS_WM_UBWC_MODE_CFG" in text
        and "writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(wm))"
        in text,
        "post_rc": "CLC_RNDCLAMP_POST_Y" in text,
        "mid_rc": "0x4800" in text and "RNDCLAMP_MID" in text,
        "plain_disp": "MODE_QCOM_PLAIN" in text and "DISP_Y_WM" in text,
        "pack_6268": "vfe_480_pack(vfe, 0x6268" in text
        and "0x0000003c" in text,
        "lsc_id1": "0x01002001" in text and "0x00530053" in text
        and "last_x == 2591 && last_y == 975" in text,
        "pdpc_id1": "0x07bf003f" in text and "Do not 0x2e58 EN" in text,
        "ds4_stride_2816": "FRONT_DS4_STRIDE" in text and "2816" in text,
        "r2pd_id1": "One variable: identity DISP R2PD on" in text
        and "core &= ~(BIT(CORE_CFG_0_DISP_DS4_R2PD)" in text
        and "identity DISP R2PD on is not the identity stall" in text,
        "pack_010c": "vfe_480_pack(vfe, 0x010c" in text
        and "0x44440001" in text,
        "pack_9c68": "vfe_480_pack(vfe, 0x9c68" in text
        and "One variable: identity 0x9c68" in text,
        "pack_8260": "vfe_480_pack(vfe, 0x8260" in text
        and "0xffff0001" in text
        and "0x8260 first-list is not the identity stall" in text,
        "pack_846c": "vfe_480_pack(vfe, 0x846c" in text
        and "One variable: identity 0x846c" in text
        and "Do not 0x8460 EN" in text
        and "0x846c first-list is not the identity stall" in text,
        "pack_8480": "vfe_480_pack(vfe, 0x8480" in text
        and "One variable: identity 0x8480" in text
        and "0x8480 first-list is not the identity stall" in text,
        "pack_8460": "vfe_480_pack(vfe, 0x8460" in text
        and "One variable: identity 0x8460" in text
        and "0x8460 first-list is not the identity stall" in text,
        "pack_8060": "vfe_480_pack(vfe, 0x8060" in text
        and "One variable: identity 0x8060" in text
        and "Do not 0x8068" in text
        and "0x8060 first-list is not the identity stall" in text,
        "pack_8068": "vfe_480_pack(vfe, 0x8068" in text
        and "One variable: identity 0x8068" in text
        and "0x8068 first-list is not the identity stall" in text,
        "pack_8e60": "vfe_480_pack(vfe, 0x8e60" in text
        and "One variable: identity 0x8e60" in text
        and "Do not 0x8e68" in text
        and "0x8e60 first-list is not the identity stall" in text,
        "pack_8e68": "vfe_480_pack(vfe, 0x8e68" in text
        and "One variable: identity 0x8e68" in text
        and "0x8e68 first-list is not the identity stall" in text,
        "pack_8660": "vfe_480_pack(vfe, 0x8660" in text
        and "One variable: identity 0x8660" in text
        and "Do not 0x8668" in text
        and "0x8660 first-list is not the identity stall" in text,
        "pack_8668": "vfe_480_pack(vfe, 0x8668" in text
        and "One variable: identity 0x8668" in text
        and "0x8668 first-list is not the identity stall" in text,
        "pack_7e6c": "vfe_480_pack(vfe, 0x7e6c" in text
        and "One variable: identity 0x7e6c" in text
        and "Do not 0x7e80" in text
        and "Do not 0x7e60 EN" in text
        and "0x7e6c first-list is not the identity stall" in text,
        "pack_7e80": "vfe_480_pack(vfe, 0x7e80" in text
        and "One variable: identity 0x7e80" in text
        and "0x7e80 first-list is not the identity stall" in text,
        "pack_7e60": "vfe_480_pack(vfe, 0x7e60" in text
        and "One variable: identity 0x7e60" in text,
        "display_full_crop": (
            "0x00000001, 0x00000600, 0x0a1f05bf, 0xc023d82c" in text
            and "0x00000001, 0x00000600, 0x0a1f05bf, 0xc047b058" in text
        ),
        "display_full_rc": (
            "0x00000527, 0x0000090f" in text
            and "0x00000293, 0x00000487" in text
        ),
        "identity_first_list_gated": "out_w == 2592 && out_h == 1952" in text,
        "path": str(overlay),
    }


def collect_live(serial: str, out: Path, reacquire: bool) -> None:
    out.mkdir(parents=True, exist_ok=True)
    su(
        serial,
        "echo 0x0300800D > /sys/module/cam_debug_util/parameters/debug_mdl",
        check=False,
    )
    if reacquire:
        adb(serial, "shell", "am", "force-stop", "com.android.camera", check=False)
        su(serial, "dmesg -C", check=False)
        adb(
            serial,
            "shell",
            "am",
            "start",
            "-a",
            "android.media.action.STILL_IMAGE_CAMERA",
            "--ez",
            "android.intent.extra.USE_FRONT_CAMERA",
            "true",
            check=False,
        )
        run(["sleep", "4"], check=False)

    dumpsys = adb(serial, "shell", "dumpsys", "media.camera", check=False, timeout=45)
    (out / "dumpsys-media-camera.txt").write_text(dumpsys)
    (out / "interrupts.txt").write_text(su(serial, "cat /proc/interrupts"))
    (out / "dmesg.txt").write_text(su(serial, "dmesg"))
    gdsc = su(
        serial,
        "for d in /sys/class/devfreq /sys/kernel/debug /sys/devices/platform; "
        "do true; done; "
        "ls /sys/class/regulator 2>/dev/null | head; "
        "for i in /sys/class/regulator/regulator.*; do "
        "n=$(cat $i/name 2>/dev/null); "
        "echo $i $n enable=$(cat $i/enable 2>/dev/null); "
        "done | grep -iE 'ife|titan|camss' || true",
        check=False,
    )
    (out / "gdsc.txt").write_text(gdsc)
    vendor = su(
        serial,
        "ls -l /data/vendor/camera 2>/dev/null; "
        "find /data/vendor/camera /data/local/tmp -name '*IFE*RegDump*' "
        "-o -name '*ife*dump*' -o -name '*RegDump*' 2>/dev/null | head -50; "
        "cat /data/vendor/camera/camxoverridesettings.txt 2>/dev/null | head -80",
        check=False,
    )
    (out / "vendor-camera.txt").write_text(vendor)
    logcat = adb(
        serial,
        "logcat",
        "-d",
        "-t",
        "2000",
        "-s",
        "CamX:V",
        "CamX:I",
        "CamX:D",
        "*:S",
        check=False,
        timeout=45,
    )
    keep = []
    for line in logcat.splitlines():
        if re.search(
            r"CamX|IFE|CSID|RDI|NV12|UBWC|SoftISP|MNDS|FULL Y|titan480|"
            r"RealTimeFeature|OutputPort",
            line,
            re.I,
        ):
            keep.append(line)
    (out / "logcat-camx.txt").write_text("\n".join(keep[-4000:]) + "\n")
    mem = su(
        serial,
        "ls -l /dev/mem 2>/dev/null; "
        "/data/local/tmp/dagu-open-mem 2>&1 | head -8 || true",
        check=False,
    )
    (out / "mem-probe.txt").write_text(mem)
    (out / "props.txt").write_text(
        su(
            serial,
            "getprop | grep -iE 'camera|ddr' | head -80",
            check=False,
        )
    )


def load_capture(serial: str, raw: Path) -> Capture:
    cap = Capture(serial=serial)
    dumpsys = (raw / "dumpsys-media-camera.txt").read_text(errors="replace") if (raw / "dumpsys-media-camera.txt").exists() else ""
    cap.camera_active = bool(
        re.search(r"Active Camera Clients:[\s\S]*?Camera ID: [01]", dumpsys)
        or re.search(r"Client Package Name: com.android.camera", dumpsys)
    )
    dmesg = (raw / "dmesg.txt").read_text(errors="replace") if (raw / "dmesg.txt").exists() else ""
    # Previous dump layout used wm-live.txt / dmesg-acquire.txt
    extra = ""
    for name in (
        "wm-live.txt",
        "dmesg-acquire.txt",
        "dmesg-tail.txt",
        "dmesg-wm.txt",
        "dmesg-wm-acquire.txt",
    ):
        p = raw / name
        if p.exists():
            extra += "\n" + p.read_text(errors="replace")
        ife = raw / "ife-live" / name
        if ife.exists():
            extra += "\n" + ife.read_text(errors="replace")
    cap.wms = parse_wm_dmesg(dmesg + extra)
    irq_txt = (raw / "interrupts.txt").read_text(errors="replace") if (raw / "interrupts.txt").exists() else ""
    if not irq_txt:
        live = raw / "ife-live" / "interrupts.txt"
        if live.exists():
            irq_txt = live.read_text(errors="replace")
    cap.irq = parse_irqs(irq_txt)
    logcat = (raw / "logcat-camx.txt").read_text(errors="replace") if (raw / "logcat-camx.txt").exists() else ""
    cap.graph, cap.softisp = parse_graph(logcat + "\n" + dumpsys)
    mem = (raw / "mem-probe.txt").read_text(errors="replace") if (raw / "mem-probe.txt").exists() else ""
    cap.mem_blocked = "No such device" in mem or "ENODEV" in mem or not mem
    vendor = (raw / "vendor-camera.txt").read_text(errors="replace") if (raw / "vendor-camera.txt").exists() else ""
    cap.regdump_files = re.findall(r"\S*RegDump\S*", vendor)
    if not cap.wms:
        cap.notes.append("no WM CAM_DBG in this capture (need --reacquire while preview starts)")
    if cap.mem_blocked:
        cap.notes.append("IFE MMIO blocked (STRICT_DEVMEM). packer/0x4800 not in this snapshot")
    return cap


def decode_wm(c: WmClient) -> dict:
    mode = None
    if c.en_cfg is not None:
        mode = "PLAIN" if ((c.en_cfg >> 16) & 3) == 0 else "MIPI_RAW"
    return {
        "wm": c.index,
        "name": WM_NAME.get(c.index, f"WM{c.index}"),
        "en_cfg": hex(c.en_cfg) if c.en_cfg is not None else None,
        "mode": mode,
        "width": c.width,
        "height": c.height,
        "stride": c.stride,
        "slice_h": c.slice_h,
        "ubwc": c.ubwc,
        "meta": c.meta,
        "frame_inc": c.frame_inc,
        "h_init": hex(c.h_init) if c.h_init is not None else None,
        "packer": hex(c.packer) if c.packer is not None else None,
        "burst": hex(c.burst) if c.burst is not None else None,
        "src": c.src,
    }


def ranked_gaps(cap: Capture, linux: dict) -> list[dict]:
    """What Linux still needs for hardware NV12. SoftISP is never a gap-closer."""
    gaps = []
    disp_y = cap.wms.get(4)
    if disp_y and disp_y.ubwc:
        gaps.append(
            {
                "id": "linear-vs-ubwc",
                "severity": "P0",
                "android": (
                    "DISP（Display path，显示通路）WM（Write Master，AXI 写通道）4/5 "
                    "活路径是 UBWC（Universal Bandwidth Compression，高通带宽压缩）"
                    " identity 2592，给 IPE（Image Processing Engine，图像处理引擎）"
                ),
                "linux": (
                    "V4L2 线性 NV12（YUV 4:2:0 semi-planar，半平面亮度/色度），"
                    "压缩机关掉；产品口是 Display Full 2320×1320"
                ),
                "do": (
                    "不要开 UBWC（Universal Bandwidth Compression，高通带宽压缩）压缩机，"
                    "不要灌 1MB 混合第一表，不要刷未测 0x7e60。"
                    "只抄 DISP（Display path，显示通路）线性 "
                    "WM（Write Master，AXI 写通道）4/5 dest。"
                ),
            }
        )
    if not linux.get("display_full_crop") or not linux.get("display_full_rc"):
        gaps.append(
            {
                "id": "display-full-linear",
                "severity": "P0",
                "android": (
                    "Heap Display Full Crop last 0x0a1f05bf 相位 0xc023d82c / "
                    "0xc047b058；RC（RoundClamp，四舍五入钳位）dest 2320×1320"
                ),
                "linux": "identity 第一表 / 0x7e60 续包仍在执行",
                "do": (
                    "回到 #386/#394 Display Full：Crop/MNDS（MN Down Scaler，M/N 下采样器）"
                    " last 0x0a1f05bf + RC（RoundClamp，四舍五入钳位）+ "
                    "WM（Write Master，AXI 写通道）4/5 同套 2320×1320。"
                    "停 identity 第一表。不要 Dual-IFE COMP_CFG。"
                ),
            }
        )
    else:
        gaps.append(
            {
                "id": "chroma-1984",
                "severity": "P0",
                    "android": (
                        "CamX（Camera eXtension，高通相机用户态框架）Display full path "
                        "2304×1296 UBWC（Universal Bandwidth Compression，高通带宽压缩）；"
                        "MNDS（MN Down Scaler，M/N 下采样器）2314×1314。"
                        "1MB CDM（Camera Data Mover，相机命令搬运器）opcode 4 "
                        "WM（Write Master，AXI 写通道）4/5 是 identity 2592 packer 0xb，"
                        "不是 2320 线性。"
                    ),
                "linux": (
                    "#386 RC（RoundClamp，四舍五入钳位）+WM（Write Master，AXI 写通道）"
                    " 2320 写出 4591616 / 4593600，chroma 短 1984"
                ),
                "do": (
                    "一刀只动一个与 dest 匹配的 CLC（Camera Logic Core，相机逻辑核）/"
                    "WM（Write Master，AXI 写通道）量。高度/stride/FRAME_INCR/"
                    "MNDS（MN Down Scaler，M/N 下采样器） Y H_PHASE 0xc023d82c 与 "
                    "MNDS（MN Down Scaler，M/N 下采样器） Y H_STRIPE 0x090f0000 与 "
                    "MNDS（MN Down Scaler，M/N 下采样器） Y V_PHASE 0x0011d7a9 与 "
                    "Crop Y V_PHASE 0xc023d909 与 "
                    "Crop Y V_STRIPE 0x02df0000 与 "
                    "Crop C V_STRIPE 0x016f0000 与 "
                    "Crop C V_PHASE 0xc047b212 与 "
                    "Crop C V_SIZE 0x016f0000 与 "
                    "Crop Y V_SIZE 0x02df0000 与 "
                    "Crop C H_STRIPE 0x090f0000 已证伪。"
                    "禁止无 VERB hex 盲写 Crop Y H_STRIPE。"
                    "后置 #365 三帧 9331200 完整。#499 最后一行 chroma "
                    "从 0xff460eb0 写 336 字节停在 4K 页 0xff461000"
                    "（336+1984=2320）；#382 2304 是 256+2048。"
                    "CAF 线性 FRAME_INCR=stride×slice_h，4K ALIGNUP 只给 "
                    "UBWC（Universal Bandwidth Compression，高通带宽压缩）。"
                    "后置最后一行也跨 4K 却写满——禁止 ALIGN_UP FRAME_INCR。"
                    "Stripe0 / H_STRIPE dest KEEP 不是杠杆（后置 9-word 也是 0）。"
                    "下一刀：HyperOS 只读抓同一包线性 IMAGE_CFG_0 "
                    "（kernel CAM_DBG WM:4/5 image height and width / frame_inc，"
                    "加上 Crop 0x0a1f05bf）。禁止 identity 0x0a1f0000 / "
                    "MNDS H_PAD / PIXEL dest last。门 ≥3×4593600，UV~128，viol≠19。"
                    "禁止 0x7e60。"
                ),
            }
        )
    if cap.softisp:
        gaps.append(
            {
                "id": "softisp-false-path",
                "severity": "P0",
                "android": "graph looks like SoftISP — unexpected for Camera ID 1 preview",
                "linux": "must not follow CPU demosaic",
                "do": "Re-check camera ID 1 graph name before copying CLC（Camera Logic Core，相机逻辑核）",
            }
        )
    return gaps


def write_report(
    out: Path,
    cap: Capture,
    linux: dict,
    gaps: list[dict],
    cdm_keep: list[dict] | None = None,
) -> str:
    wms = [decode_wm(c) for _, c in sorted(cap.wms.items())]
    y = cap.wms.get(4)
    c = cap.wms.get(5)
    lines = [
        "# Titan 480 IFE（Image Front End，图像前端）：安卓活预览 → Linux 硬件 NV12（YUV 4:2:0 semi-planar，半平面亮度/色度）",
        "",
        "目标：IFE（Image Front End，图像前端）DISP（Display path，显示通路）线性 NV12（YUV 4:2:0 semi-planar，半平面亮度/色度）。禁止 CPU SoftISP（Software Image Signal Processor，软件图像信号处理器）。",
        f"采集：serial={cap.serial}  graph={cap.graph or '?'}  camera={'open' if cap.camera_active else 'idle'}",
        "",
        "## 结论",
        "",
    ]
    if cap.graph and not cap.softisp:
        lines.append(
            f"Camera ID 1 活预览是 **{cap.graph}**（IFE（Image Front End，图像前端）PIX（Pixel path，像素通路）+ IPE（Image Processing Engine，图像处理引擎）），不是 SoftISP（Software Image Signal Processor，软件图像信号处理器）。"
        )
        lines.append(
            "Linux CAMSS（Camera Subsystem，相机子系统）产品口不是这条 UBWC（Universal Bandwidth Compression，高通带宽压缩）identity，而是 Display Full 线性 2320×1320。"
        )
    if y and c:
        kind = "UBWC（Universal Bandwidth Compression，高通带宽压缩）" if y.ubwc else "linear"
        lines.append(
            f"DISP（Display path，显示通路）WM（Write Master，AXI 写通道）4/5 {kind} {y.width}x{y.height} / {c.width}x{c.height}，"
            f"en_cfg={hex(y.en_cfg) if y.en_cfg is not None else '?'}。"
        )
        lines.append(
            "Topology XML（Extensible Markup Language，可扩展标记语言）：WM（Write Master，AXI 写通道）4/5 = DISP（Display path，显示通路）Y/C（Luma/Chroma，亮度/色度）；"
            "WM（Write Master，AXI 写通道）6/7 = TAP（Tap / downscale tap，抽头）；"
            "WM（Write Master，AXI 写通道）8/9 = FD（Face Detection，人脸检测）。Linux 只收 WM（Write Master，AXI 写通道）4/5 线性。"
        )
    keep_n = len(cdm_keep or [])
    if keep_n:
        lines.append(
            f"DISP（Display path，显示通路）线性子集 **{keep_n}** 包：Crop last 0x0a1f05bf + 相位 0xc023d82c / RC（RoundClamp，四舍五入钳位）0x527/0x90f。1MB 第一表的 TAP（Tap / downscale tap，抽头）/ FD（Face Detection，人脸检测）/ stats 禁止灌。"
        )
    else:
        lines.append(
            "缺 DISP（Display path，显示通路）线性子集：分析器 fail，不准推荐下一包 stats。"
        )
    ife_irq = sum(v for k, v in cap.irq.items() if k.startswith("ife") and "lite" not in k)
    if ife_irq:
        lines.append(f"IFE（Image Front End，图像前端）IRQ 合计 {ife_irq}：像素管线在出数。")
    lines += ["", "## 安卓 BUS（CAM_DBG / 既往 dump）", ""]
    lines.append("| WM | 端口 | en_cfg | 尺寸 | stride | frame_inc | h_init | packer | burst | UBWC | src |")
    lines.append("|----|------|--------|------|--------|-----------|--------|--------|-------|------|-----|")
    port_of = {
        4: "DISP Y",
        5: "DISP C",
        6: "TAP DS4",
        7: "TAP DS16",
        8: "FD Y",
        9: "FD C",
        23: "RDI0",
        24: "RDI1",
    }
    for w in wms:
        if w["wm"] not in (4, 5, 6, 7, 8, 9, 23, 24):
            continue
        pname = port_of.get(w["wm"], w["name"])
        lines.append(
            f"| {w['wm']} | {pname} | {w['en_cfg']} | "
            f"{w['width']}x{w['height']} | {w['stride']} | "
            f"{w['frame_inc']} | {w.get('h_init')} | {w.get('packer')} | "
            f"{w.get('burst')} | "
            f"{'yes' if w['ubwc'] else 'no'} | {w.get('src') or 'dmesg'} |"
        )
    lines += ["", "## Topology 端口：KEEP vs FORBID", ""]
    if cdm_keep:
        for h in cdm_keep[:24]:
            note = h.get("note") or (
                f"addr=0x{h.get('addr', 0):04x} n={h.get('n')}"
            )
            lines.append(f"- KEEP {h.get('port', 'DISP')}: {note}")
    else:
        lines.append("- （无 KEEP）")
    lines.append("- FORBID：Crop 640 `0xc081999a`、identity last `0x0a1f079f`、MID 480×640、OUT 488×648、TAP（Tap / downscale tap，抽头）/ FD（Face Detection，人脸检测）/ stats、UBWC（Universal Bandwidth Compression，高通带宽压缩）packer 3")
    lines += ["", "## CAF 对照（不是猜测）", ""]
    lines.append(
        "- NV12 与 UBWC_NV12 的 packer 都是 `PLAIN_8_LSB_MSB_10 = 3`"
    )
    lines.append(
        f"- COMP_GRP_1 启动必写 `ubwc_static_ctrl={hex(UBWC_STATIC_LPDDR5)}` @ 0xAA58（LPDDR5）"
    )
    lines.append("- 活预览 WM4/5 会把 UBWC `mode_cfg` bit0 置 1；Linux V4L2 线性必须保持 0")
    lines.append("- Display Full CLC 顺序：")
    for name, off, note in CLC_DISPLAY:
        lines.append(f"  - `{name}` `{hex(off)}` — {note}")
    lines += ["", "## Linux overlay 已写", ""]
    lines.append(f"- packer3: {linux.get('packer3')}")
    lines.append(f"- ubwc_static 0x1036: {linux.get('ubwc_static')}")
    lines.append(f"- UBWC compressor off: {linux.get('ubwc_mode_off')}")
    lines.append(f"- POST RoundClamp: {linux.get('post_rc')}")
    lines.append(f"- MID RoundClamp 0x4800: {linux.get('mid_rc')}")
    lines.append(f"- first-list 0x6268: {linux.get('pack_6268')}")
    lines.append(f"- identity LSC 0x3658/0x3668: {linux.get('lsc_id1')}")
    lines.append(f"- identity PDPC 0x2e68 window: {linux.get('pdpc_id1')}")
    lines.append(f"- dummy WM6 stride 2816: {linux.get('ds4_stride_2816')}")
    lines.append(f"- identity DISP R2PD on 0x60000800: {linux.get('r2pd_id1')}")
    lines.append(f"- first-list 0x010c 0x44440001: {linux.get('pack_010c')}")
    lines.append(f"- first-list 0x9c68: {linux.get('pack_9c68')}")
    lines.append(f"- first-list 0x8260 EN: {linux.get('pack_8260')}")
    lines.append(f"- first-list 0x846c window: {linux.get('pack_846c')}")
    lines.append(f"- first-list 0x8480 window: {linux.get('pack_8480')}")
    lines.append(f"- first-list 0x8460 EN: {linux.get('pack_8460')}")
    lines.append(f"- first-list 0x8060 EN: {linux.get('pack_8060')}")
    lines.append(f"- first-list 0x8068 window: {linux.get('pack_8068')}")
    lines.append(f"- first-list 0x8e60 EN: {linux.get('pack_8e60')}")
    lines.append(f"- first-list 0x8e68 window: {linux.get('pack_8e68')}")
    lines.append(f"- first-list 0x8660 EN: {linux.get('pack_8660')}")
    lines.append(f"- first-list 0x8668 window: {linux.get('pack_8668')}")
    lines.append(f"- first-list 0x7e6c window: {linux.get('pack_7e6c')}")
    lines.append(f"- first-list 0x7e80 window: {linux.get('pack_7e80')}")
    lines.append(f"- first-list 0x7e60 EN (must not execute): {linux.get('pack_7e60')}")
    lines.append(f"- Display Full Crop 0x0a1f05bf: {linux.get('display_full_crop')}")
    lines.append(f"- Display Full RC 2320×1320: {linux.get('display_full_rc')}")
    lines.append(f"- identity first-list gated on dest 2592: {linux.get('identity_first_list_gated')}")
    lines += ["", "## 硬件 NV12 缺口（按优先级）", ""]
    for g in gaps:
        lines.append(f"### {g['severity']} `{g['id']}`")
        lines.append(f"- 安卓：{g['android']}")
        lines.append(f"- Linux：{g['linux']}")
        lines.append(f"- 下一刀：{g['do']}")
        lines.append("")
    lines += ["## 禁止", ""]
    lines.append("- 刷这块 HyperOS 板 / A 槽 / `53dcc70` 的 `18d1:4ee7`")
    lines.append("- 解 CSID SOT、改 `0x0114`、改前置 skip / csiphy4")
    lines.append("- 用 DebayerCpu / GPU SoftISP / 空 PDPC EN=1「先出图」")
    lines.append("- STREAMON BUS DISP 而不开 CLC（CAMNOC hang）")
    if cap.notes:
        lines += ["", "## 采集限制", ""]
        lines += [f"- {n}" for n in cap.notes]
    lines.append("")
    report = "\n".join(lines)
    (out / "REPORT.md").write_text(report)
    facts = {
        "serial": cap.serial,
        "graph": cap.graph,
        "softisp": cap.softisp,
        "camera_active": cap.camera_active,
        "irq": cap.irq,
        "wms": wms,
        "linux": linux,
        "gaps": gaps,
        "notes": cap.notes,
        "cdm_keep": [
            {
                "port": h.get("port"),
                "src": h.get("src"),
                "addr": h.get("addr"),
                "note": h.get("note"),
            }
            for h in (cdm_keep or [])
        ],
    }
    (out / "facts.json").write_text(json.dumps(facts, indent=2) + "\n")
    return report


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--serial",
        default=os.environ.get("DAGU_ADB_SERIAL", ""),
        help="HyperOS extract tablet. Env: DAGU_ADB_SERIAL",
    )
    ap.add_argument(
        "--offline",
        type=Path,
        help="Parse an existing dump directory (no adb)",
    )
    ap.add_argument(
        "--reacquire",
        action="store_true",
        help="Force-stop and reopen com.android.camera to recapture WM acquire logs",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=None,
    )
    ap.add_argument(
        "--cdm-bin",
        type=Path,
        help="Parse a live-cdm-*.bin AHB first-list (no adb)",
    )
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    out = args.out or (root / "out/camera/ife-android-analyze" / stamp)
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=True)

    if args.offline:
        raw = args.offline.resolve()
        if not raw.exists():
            die(f"missing {raw}")
        serial = args.serial or "offline"
        cap = load_capture(serial, raw)
    else:
        serial = args.serial
        if not serial:
            die("set DAGU_ADB_SERIAL or pass --serial (HyperOS pad only)")
        assert_android_pad(serial)
        raw = out / "raw"
        print(f"==> collect {serial} -> {raw} (no flash)", file=sys.stderr)
        collect_live(serial, raw, args.reacquire)
        cap = load_capture(serial, raw)
        prior = root.parent / "dumps/dagu-android-live/camera-ife-20260916"
        if not cap.wms and prior.exists():
            extra = load_capture(serial, prior)
            cap.wms = extra.wms
            cap.notes.append(f"WM table filled from {prior} (this session had no acquire CAM_DBG)")
            if extra.graph and not cap.graph:
                cap.graph = extra.graph

    linux = linux_overlay_facts(root)
    cdm = args.cdm_bin
    dump_front = root.parent / "dumps/dagu-android-live/camera-ife-20260917-front"
    if cdm is None:
        default_cdm = dump_front / "live-cdm-1mb.bin"
        if default_cdm.exists():
            cdm = default_cdm
    packs: list[dict] = []
    if cdm is not None and cdm.exists():
        packs = parse_cdm_ahb(cdm.resolve(), out / "cdm-first-list.txt")
        cap.notes.append(f"CDM AHB parsed from {cdm} (opcode 3+4)")
        merge_cdm_wms(cap, extract_cdm_wms(packs))
    heap_hits: list[dict] = []
    heap_path = dump_front / "live-display-2304.txt"
    if heap_path.exists():
        heap_text = heap_path.read_text(errors="replace")
        (out / "live-display-2304.txt").write_text(heap_text)
        heap_hits = parse_heap_display_full(heap_text)
        cap.notes.append(f"Display Full heap from {heap_path}")
    sensor_mod = (
        root.parent / "dumps/dagu-android-live/camera/com.qti.sensormodule.dagu_aac_imx596_front.bin"
    )
    if sensor_mod.exists():
        sm = parse_sensor_module_modes(sensor_mod)
        sm_lines = [
            "# imx596 sensor module（不是 Chromatix，不是 dest）",
            "",
            f"file: {sm['path']}",
            "",
            "IFE（Image Front End，图像前端）相关模式（u32 WxH）：",
        ]
        for m in sm["modes"]:
            sm_lines.append(
                f"- 0x{m['off']:x}: {m['w']}x{m['h']} (word before width={m['before']})"
            )
        sm_lines += [
            "",
            "delayUs I2C 载荷，**不是** IFE（Image Front End，图像前端）dest："
            + ", ".join(sm["delayUs_not_dest"]),
            "这份 bin 里的 2304 是 I2C 0x0900，不是 IMAGE_CFG。",
            "没有 2304×1296 成对。前置 tuned Chromatix 仍未拉过。",
        ]
        (out / "SENSOR-MODULE.md").write_text("\n".join(sm_lines) + "\n")
        cap.notes.append(
            "sensor module modes "
            + ", ".join(f"{m['w']}x{m['h']}" for m in sm["modes"])
            + "; delayUs "
            + ",".join(sm["delayUs_not_dest"])
            + " are not dest"
        )
    gaps = ranked_gaps(cap, linux)
    cdm_keep = disp_linear_subset(packs, heap_hits)
    if not cdm_keep:
        cap.notes.append("FAIL: no DISP linear subset (Crop 0x0a1f05bf / RC 2320)")
    report = write_report(out, cap, linux, gaps, cdm_keep)
    print(report)
    print(f"==> wrote {out / 'REPORT.md'}", file=sys.stderr)
    if not cdm_keep:
        die(
            "no DISP linear subset in CDM/heap; refuse next-pack stats. "
            "Need Crop last 0x0a1f05bf + 0xc023d82c or RC dest 0x527/0x90f"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
