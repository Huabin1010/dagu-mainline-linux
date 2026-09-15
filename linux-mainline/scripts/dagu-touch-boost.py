#!/usr/bin/env python3
"""Raise GPU/CPU floors while touching, Chrome video, or camera SoftISP.

Idle stays on simple_ondemand / schedutil (GPU min 587 MHz). A hold-drag
or a <video> used to bounce 587↔670 and leave the prime core at 845 MHz,
which is the felt hitch / dropped frame. This does not change Chrome
CPU vs GPU raster. Do not set governor=performance.

Himax is spi-gpio bitbang (IRQF_ONESHOT thread). SoftISP on 5MP/12MP RAW
saturates the cluster and mutter's libinput loop starves — taps still
wake the backlight via logind, but folders/close-window do not respond.
Do not pin SoftISP to the big cluster: pin it to silver CPU0-3 and keep
Himax/mutter on Gold. Signal is any userspace fd on `/dev/video0` or
`/dev/video3` (plus gst-launch holding the loopback nodes).
"""
from __future__ import annotations

import glob
import os
import struct
import time

EV_KEY, EV_ABS = 0x01, 0x03
ABS_MT_TRACKING_ID = 0x39
BTN_TOUCH = 0x14A
EVENT = struct.Struct("llHHi")

GPU_MIN = "/sys/class/devfreq/3d00000.gpu/min_freq"
GPU_IDLE = "587000000"
GPU_HOLD = "670000000"

CPU = (
    ("/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq", "300000", "1248000"),
    ("/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq", "710400", "1766400"),
    ("/sys/devices/system/cpu/cpufreq/policy7/scaling_min_freq", "844800", "1977600"),
)

HOLD_TAIL_S = 0.18
VIDEO_SCAN_S = 0.12
SOFTISP_CPUS = frozenset({0, 1, 2, 3})
ALL_CPUS = frozenset(range(os.cpu_count() or 8))
# comm is TASK_COMM_LEN=16 including NUL → 15 chars.
SKIP_PIN = {
    "gnome-shell",
    "Xwayland",
    "dagu-touch-boo",
    "dagu-himax-irq",
}


def write(path: str, value: str) -> None:
    try:
        with open(path, "w") as f:
            f.write(value + "\n")
    except OSError:
        pass


def find_himax() -> str:
    for name in sorted(glob.glob("/sys/class/input/event*/device/name")):
        try:
            text = open(name, "r", encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        if "Himax" in text or "HX83121" in text:
            return "/dev/input/" + name.split("/")[4]
    return "/dev/input/event3"


def apply(hold: bool) -> None:
    write(GPU_MIN, GPU_HOLD if hold else GPU_IDLE)
    for path, idle, boosted in CPU:
        write(path, boosted if hold else idle)


BROWSER_MARKERS = (
    b"/opt/google/chrome/chrome",
    b"/usr/lib/chromium/chromium",
    b"/usr/bin/chromium",
)
CAM_NODES = ("/dev/video0", "/dev/video3")
LOOP_NODES = ("/dev/video20", "/dev/video21")
CAM_COMMS = {
    "snapshot",
    "gnome-snapshot",
    "pipewire",
    "wireplumber",
    "cam",
    "gst-launch-1.0",
}
VENUS_NODES = (
    "/dev/video14",
    "/dev/video15",
    "/dev/video-dec0",
    "/dev/video-enc0",
)


def _is_browser(cmd: bytes) -> bool:
    return any(m in cmd for m in BROWSER_MARKERS)


def _comm(pid: str) -> str:
    try:
        with open(f"/proc/{pid}/comm", "r", encoding="utf-8", errors="ignore") as f:
            return f.read().strip()
    except OSError:
        return ""


def _is_cam_comm(comm: str) -> bool:
    if comm in CAM_COMMS:
        return True
    return comm.startswith("gst-launch") or comm.startswith("gnome-snapsho")


def _has_fd(pid: str, nodes: tuple[str, ...]) -> bool:
    try:
        fds = os.listdir(f"/proc/{pid}/fd")
    except OSError:
        return False
    for fd in fds:
        try:
            target = os.readlink(f"/proc/{pid}/fd/{fd}")
        except OSError:
            continue
        if target in nodes:
            return True
    return False


def _has_venus_fd(pid: str) -> bool:
    return _has_fd(pid, VENUS_NODES)


def chrome_video_playing() -> bool:
    """True while Chromium/Chrome is in a Venus or video-compositor path."""
    try:
        pids = os.listdir("/proc")
    except OSError:
        return False
    for pid in pids:
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read()
        except OSError:
            continue
        if not _is_browser(cmd):
            continue
        if _has_venus_fd(pid):
            return True
        if b"--type=" in cmd and b"--type=renderer" not in cmd:
            continue
        task = f"/proc/{pid}/task"
        try:
            tids = os.listdir(task)
        except OSError:
            continue
        for tid in tids:
            try:
                with open(f"{task}/{tid}/comm", "r", encoding="utf-8", errors="ignore") as f:
                    name = f.read().strip()
            except OSError:
                continue
            if name.startswith(("VideoFrame", "FFmpeg", "VideoDecod", "V4L2", "Media")):
                return True
    return False


def _iter_pids():
    try:
        pids = os.listdir("/proc")
    except OSError:
        return
    for pid in pids:
        if pid.isdigit():
            yield pid


def _has_softisp_thread(pid: str) -> bool:
    task = f"/proc/{pid}/task"
    try:
        tids = os.listdir(task)
    except OSError:
        return False
    for tid in tids:
        try:
            with open(f"{task}/{tid}/comm", "r", encoding="utf-8", errors="ignore") as f:
                name = f.read().strip()
        except OSError:
            continue
        if name.startswith(("SWIspWorker", "DebayerCpu")):
            return True
    return False


def camera_streaming() -> bool:
    """True while Snapshot/cam/gst is up, or a SoftISP worker thread exists.

    pipewire/wireplumber keep `/dev/video0` open for enumeration. That is
    not STREAMON — do not boost or pin from the fd alone.
    """
    for pid in _iter_pids():
        comm = _comm(pid)
        if comm in ("snapshot", "gnome-snapshot", "cam") or comm.startswith(
            ("gst-launch", "gnome-snapsho")
        ):
            return True
        if _has_softisp_thread(pid):
            return True
        if _is_cam_comm(comm) and _has_fd(pid, LOOP_NODES):
            return True
    return False


def pin_softisp(enable: bool) -> None:
    """Keep DebayerCpu/libcamera off Gold so mutter and Himax still run."""
    cpus = SOFTISP_CPUS if enable else ALL_CPUS
    for pid in _iter_pids():
        comm = _comm(pid)
        if comm in SKIP_PIN:
            continue
        if not (_has_fd(pid, CAM_NODES) or _has_fd(pid, LOOP_NODES)):
            continue
        try:
            os.sched_setaffinity(int(pid), cpus)
        except (OSError, ValueError, PermissionError):
            continue


def main() -> None:
    dev = find_himax()
    fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
    apply(False)
    pin_softisp(False)
    contacts = 0
    holding = False
    drop_at = None
    video = False
    last_scan = 0.0
    pinned = False
    while True:
        now = time.monotonic()
        try:
            buf = os.read(fd, EVENT.size * 64)
        except BlockingIOError:
            buf = b""
        if buf:
            for off in range(0, len(buf) - EVENT.size + 1, EVENT.size):
                _sec, _usec, typ, code, value = EVENT.unpack_from(buf, off)
                if typ == EV_ABS and code == ABS_MT_TRACKING_ID:
                    if value >= 0:
                        contacts += 1
                    elif contacts > 0:
                        contacts -= 1
                elif typ == EV_KEY and code == BTN_TOUCH:
                    contacts = 1 if value else 0
        if now - last_scan >= VIDEO_SCAN_S:
            video = chrome_video_playing() or camera_streaming()
            if video and not pinned:
                pin_softisp(True)
                pinned = True
            elif not video and pinned:
                pin_softisp(False)
                pinned = False
            last_scan = now
        want = contacts > 0 or video
        if want:
            drop_at = None
            if not holding:
                holding = True
                apply(True)
        elif holding:
            if drop_at is None:
                drop_at = now + HOLD_TAIL_S
            elif now >= drop_at:
                holding = False
                drop_at = None
                apply(False)
        time.sleep(0.004)


if __name__ == "__main__":
    main()
