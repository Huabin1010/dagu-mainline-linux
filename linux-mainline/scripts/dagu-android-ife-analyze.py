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


def run(args: list[str], check: bool = True, text: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=check, text=text, capture_output=True)


def adb(serial: str, *args: str, check: bool = True) -> str:
    r = run(["adb", "-s", serial, *args], check=check)
    if check is False and r.returncode:
        return (r.stdout or "") + (r.stderr or "")
    return r.stdout or ""


def su(serial: str, cmd: str, check: bool = True) -> str:
    # One adb-shell string so Magisk su sees redirects.
    wrapped = "su -c " + repr(cmd)
    r = run(["adb", "-s", serial, "shell", wrapped], check=False)
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
            check=False,
        )
        run(["sleep", "4"], check=False)

    dumpsys = adb(serial, "shell", "dumpsys", "media.camera", check=False)
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
    logcat = adb(serial, "logcat", "-d", "-b", "all", check=False)
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
        re.search(r"Active Camera Clients:[\s\S]*?Camera ID: 0", dumpsys)
        or re.search(r"Client Package Name: com.android.camera", dumpsys)
    )
    dmesg = (raw / "dmesg.txt").read_text(errors="replace") if (raw / "dmesg.txt").exists() else ""
    # Previous dump layout used wm-live.txt / dmesg-acquire.txt
    extra = ""
    for name in ("wm-live.txt", "dmesg-acquire.txt", "dmesg-tail.txt"):
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
    cap.graph, cap.softisp = parse_graph(logcat)
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
    }


def ranked_gaps(cap: Capture, linux: dict) -> list[dict]:
    """What Linux still needs for hardware NV12. SoftISP is never a gap-closer."""
    gaps = []
    disp_y = cap.wms.get(4)
    disp_c = cap.wms.get(5)
    if disp_y and disp_y.ubwc:
        gaps.append(
            {
                "id": "linear-vs-ubwc",
                "severity": "P0",
                "android": "DISP WM4/5 活路径是 UBWC（meta、stride 2560、高度 pad）",
                "linux": "V4L2 线性 NV12，压缩机关掉（mode_cfg=0）",
                "do": (
                    "继续走线性，不要开 UBWC 压缩机。"
                    "下一块 CLC 是中段 RoundClamp 0x4800/0x4a00"
                    "（Display Full 里 Crop11 和 MNDS 之间）。"
                    "不要把安卓 meta/stride/slice pad 抄进 v4l2。"
                ),
            }
        )
    if not linux.get("mid_rc"):
        gaps.append(
            {
                "id": "mid-roundclamp",
                "severity": "P0",
                "android": "CamX Display Full CDM 在 0x4860/0x4a60 写 RoundClamp idx1",
                "linux": "POST 0x5000/0x5200 已 EN；MID 0x4800/0x4a00 仍 EN=0",
                "do": (
                    "按 POST 同样写法打开 MID：MODULE_CFG 0x3c01，clamp 在 +0x70。"
                    "不要改 MNDS C V_IN、0x0114、SOT mask。"
                ),
            }
        )
    if not linux.get("packer3"):
        gaps.append(
            {
                "id": "packer",
                "severity": "P0",
                "android": "CAF NV12 and UBWC_NV12 both PACKER_FMT 3",
                "linux": "packer 3 missing",
                "do": "PLAIN WM PACKER_CFG=3, RDI stays 0",
            }
        )
    if not linux.get("ubwc_static"):
        gaps.append(
            {
                "id": "ubwc-static",
                "severity": "P1",
                "android": f"COMP_GRP_1 ORs ubwc_static_ctrl {hex(UBWC_STATIC_LPDDR5)} @ 0xAA58",
                "linux": "0xAA58 not programmed",
                "do": "Write LPDDR5 0x1036; still leave compressor off",
            }
        )
    gaps.append(
        {
            "id": "mmio",
            "severity": "P1",
                "android": "STRICT_DEVMEM 挡住 /dev/mem；IFE_RegDump 只在 CamX flush/hang 出现",
                "linux": "读不到安卓活 packer / 0xB048 / 0x4860",
                "do": (
                    "若 CamX 写出 /data/vendor/camera/IFE_RegDump_*.txt，解析 "
                    "0xB018 packer、0xB048 mode_cfg、0x4860/0x4a60 MODULE_CFG。"
                    "不要为了放宽 STRICT_DEVMEM 去刷这块板。"
                ),
        }
    )
    if cap.softisp:
        gaps.append(
            {
                "id": "softisp-false-path",
                "severity": "P0",
                "android": "graph looks like SoftISP — unexpected for rear preview",
                "linux": "must not follow CPU demosaic",
                "do": "Re-check camera ID 0 graph name before copying CLC",
            }
        )
    return gaps


def write_report(out: Path, cap: Capture, linux: dict, gaps: list[dict]) -> str:
    wms = [decode_wm(c) for _, c in sorted(cap.wms.items())]
    y = cap.wms.get(4)
    c = cap.wms.get(5)
    lines = [
        "# Titan 480 IFE：安卓活预览 → Linux 硬件 NV12",
        "",
        "目标：IFE DISP 线性 NV12。禁止 CPU SoftISP / EGL SoftISP / 开 CDSP 交差。",
        f"采集：serial={cap.serial}  graph={cap.graph or '?'}  camera0={'open' if cap.camera_active else 'idle'}",
        "",
        "## 结论",
        "",
    ]
    if cap.graph and not cap.softisp:
        lines.append(
            f"安卓后置预览是 **{cap.graph}**（IFE PIX + IPE），不是 SoftISP。"
        )
    if y and c:
        kind = "UBWC" if y.ubwc else "linear"
        lines.append(
            f"DISP WM4/5 {kind} {y.width}x{y.height} / {c.width}x{c.height}，"
            f"en_cfg={hex(y.en_cfg) if y.en_cfg is not None else '?'}（PLAIN）。"
        )
    ife_irq = sum(v for k, v in cap.irq.items() if k.startswith("ife") and "lite" not in k)
    if ife_irq:
        lines.append(f"IFE IRQ 合计 {ife_irq}：像素管线在出数。")
    lines += ["", "## 安卓 BUS（CAM_DBG / 既往 dump）", ""]
    lines.append("| WM | 端口 | en_cfg | 尺寸 | stride | UBWC |")
    lines.append("|----|------|--------|------|--------|------|")
    for w in wms:
        if w["wm"] not in (4, 5, 6, 7, 8, 9, 23, 24):
            continue
        lines.append(
            f"| {w['wm']} | {w['name']} | {w['en_cfg']} | "
            f"{w['width']}x{w['height']} | {w['stride']} | "
            f"{'yes' if w['ubwc'] else 'no'} |"
        )
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
    gaps = ranked_gaps(cap, linux)
    report = write_report(out, cap, linux, gaps)
    print(report)
    print(f"==> wrote {out / 'REPORT.md'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
